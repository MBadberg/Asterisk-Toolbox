#!/usr/bin/env bash
set -euo pipefail

# Asterisk Admin Menüs für Anpassungen nach der Grundinstallation (V7)
# - Voicemail je Nebenstelle ein/aus
# - Ringgruppen bearbeiten
# - Call-Waiting (Klopfen) je Nebenstelle ein/aus via AstDB
#
# Ausführung direkt im LXC-Container als root:
#   chmod +x /root/asterisk-admin.sh
#   /root/asterisk-admin.sh

SIP_CONF="/etc/asterisk/sip.conf"
EXT_CONF="/etc/asterisk/extensions.conf"
VM_CONF="/etc/asterisk/voicemail.conf"
AST_CLI="asterisk -rx"

ts() { date +"%Y%m%d-%H%M%S"; }
backup() { local f="$1"; [ -f "$f" ] && cp -a "$f" "${f}.bak.$(ts)"; }

require_files() {
  for f in "$SIP_CONF" "$EXT_CONF"; do
    if [ ! -f "$f" ]; then
      echo "Fehlt: $f – bitte Installation prüfen."
      exit 1
    fi
  done
}

reload_asterisk() {
  $AST_CLI "dialplan reload" >/dev/null 2>&1 || true
  $AST_CLI "sip reload" >/dev/null 2>&1 || true
}

# Konservative Nebenstellen-Liste aus sip.conf (kompatibel mit mawk/busybox awk)
list_extensions() {
  awk '
    BEGIN{inblk=0; ext=""; name="-"; tf=0; hd=0}
    # Neuer Abschnitt: vorherigen ggf. ausgeben
    /^\[/ {
      if (inblk && tf && hd && ext!="") { print ext " " name }
      inblk=0; tf=0; hd=0; ext=""; name="-"
    }
    # Abschnitt [<digits>] erkennen (2..4 Ziffern)
    /^\[[0-9][0-9]*\]$/ {
      s=$0
      gsub(/^\[/,"",s); gsub(/\]$/,"",s)
      if (s ~ /^[0-9][0-9]*$/) {
        ln=length(s)
        if (ln>=2 && ln<=4) { ext=s; inblk=1 } else { ext=""; inblk=0 }
      }
      next
    }
    # Kriterien für „echte“ Nebenstelle
    inblk && $0 ~ /^[ \t]*type[ \t]*=[ \t]*friend[ \t]*$/ { tf=1; next }
    inblk && $0 ~ /^[ \t]*host[ \t]*=[ \t]*dynamic[ \t]*$/ { hd=1; next }
    inblk && $0 ~ /^[ \t]*callerid[ \t]*=/ {
      # callerid="Name" <123>
      line=$0
      split(line, a, /"/)
      if (length(a) >= 3 && a[2] != "") { name=a[2] }
      next
    }
    END{
      if (inblk && tf && hd && ext!="") { print ext " " name }
    }
  ' "$SIP_CONF" | sort -n
}

ensure_vm_conf() {
  if [ ! -f "$VM_CONF" ]; then
    backup "$VM_CONF"
    cat > "$VM_CONF" <<'EOF'
[general]
format=wav49|gsm|wav
serveremail=asterISK
attach=no
maxmsg=100
maxsecs=300
minsecs=2
language=de

[default]
EOF
  fi
  grep -q '^\[default\]' "$VM_CONF" || { echo "" >> "$VM_CONF"; echo "[default]" >> "$VM_CONF"; }
}

vm_entry_exists() { local ext="$1"; grep -Eq "^[[:space:]]*${ext}[[:space:]]*=>" "$VM_CONF"; }

add_or_update_vm_entry() {
  local ext="$1" pin="$2" name="$3"
  ensure_vm_conf
  backup "$VM_CONF"
  if vm_entry_exists "$ext"; then
    sed -i -E "s|^[[:space:]]*${ext}[[:space:]]*=>.*|${ext} => ${pin},${name},,|g" "$VM_CONF"
  else
    echo "${ext} => ${pin},${name},," >> "$VM_CONF"
  fi
}

remove_vm_entry() { local ext="$1"; backup "$VM_CONF"; sed -i -E "/^[[:space:]]*${ext}[[:space:]]*=>/d" "$VM_CONF" || true; }

sip_set_mailbox() {
  local ext="$1"
  backup "$SIP_CONF"
  awk -v EXT="$ext" '
  BEGIN{inblk=0; have=0}
  {
    if ($0 ~ ("^\\["EXT"\\]$")) { print; inblk=1; have=0; next }
    if (inblk && $0 ~ /^\[/) { if (!have) print "mailbox="EXT"@default"; inblk=0 }
    if (inblk && $0 ~ /^[ \t]*mailbox[ \t]*=/) { print "mailbox="EXT"@default"; have=1; next }
    print
  }
  END{ if (inblk && !have) print "mailbox="EXT"@default" }
  ' "$SIP_CONF" > "${SIP_CONF}.new" && mv "${SIP_CONF}.new" "$SIP_CONF"
}

sip_remove_mailbox() {
  local ext="$1"
  backup "$SIP_CONF"
  awk -v EXT="$ext" '
  BEGIN{inblk=0}
  {
    if ($0 ~ ("^\\["EXT"\\]$")) { print; inblk=1; next }
    if (inblk && $0 ~ /^\[/) { inblk=0 }
    if (inblk && $0 ~ /^[ \t]*mailbox[ \t]*=/) { next }
    print
  }
  ' "$SIP_CONF" > "${SIP_CONF}.new" && mv "${SIP_CONF}.new" "$SIP_CONF"
}

ext_block_has_vmline() {
  local ext="$1"
  awk -v EXT="$ext" '
  BEGIN{sect=0; inblk=0; have=0}
  /^\[internal\]$/ { sect=1; next }
  /^\[/ { if (sect && inblk) exit; if ($0=="[internal]") {sect=1} else {sect=0}; inblk=0; next }
  sect && $0 ~ ("^exten[ \t]*=>[ \t]*"EXT",") { inblk=1 }
  inblk && /Voicemail\(/ { have=1 }
  END{ if (have) exit 0; else exit 1 }
  ' "$EXT_CONF"
}

ext_add_vmline_after_dial() {
  local ext="$1"
  backup "$EXT_CONF"
  awk -v EXT="$ext" '
  BEGIN{sect=0; inblk=0; added=0}
  /^\[internal\]$/ { print; sect=1; next }
  /^\[/ {
    if (sect && inblk && !added
