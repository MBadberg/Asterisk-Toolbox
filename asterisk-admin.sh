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
        # Länge ohne {m,n}-Quantifier prüfen
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
      # Name zwischen ersten beiden Anführungszeichen extrahieren
      n=line
      # split an doppelten Anführungszeichen (")
      # busybox/mawk können regex in split
      split(n, a, /"/)
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
serveremail=asterisk
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
    if (inblk && $0 ~ /^\\[/) { if (!have) print "mailbox="EXT"@default"; inblk=0 }
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
    if (inblk && $0 ~ /^\\[/) { inblk=0 }
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
    if (sect && inblk && !added) { print " same => n,Voicemail("EXT"@default,u)"; added=1 }
    print; if ($0!="[internal]") { sect=0 }; inblk=0; next
  }
  {
    if (sect && $0 ~ ("^exten[ \t]*=>[ \t]*"EXT",")) { print; inblk=1; next }
    if (sect && inblk && /Dial\(/) { print; if (!added) { print " same => n,Voicemail("EXT"@default,u)"; added=1 }; next }
    print
  }
  END{ if (sect && inblk && !added) print " same => n,Voicemail("EXT"@default,u)" }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ext_remove_vmline() {
  local ext="$1"
  backup "$EXT_CONF"
  awk -v EXT="$ext" '
  BEGIN{sect=0; inblk=0}
  /^\[internal\]$/ { print; sect=1; next }
  /^\[/ { print; if ($0!="[internal]") { sect=0 }; inblk=0; next }
  {
    if (sect && $0 ~ ("^exten[ \t]*=>[ \t]*"EXT",")) { print; inblk=1; next }
    if (sect && inblk && /Voicemail\(/) { next }
    print
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ensure_calltoext_helper() {
  if ! grep -q '^\[calltoext\]' "$EXT_CONF"; then
    backup "$EXT_CONF"
    cat >> "$EXT_CONF" <<'EOFCALLHELP'
; Helper-Context für Call-Waiting/DND/Voicemail-Steuerung
[calltoext]
exten => _X.,1,NoOp(Helper: call to ${EXTEN})
 same => n,Set(EXT=${EXTEN})
 ; Flags aus AstDB:
 ;   cw/<ext> = on|off   (Call-Waiting)
 ;   dnd/<ext> = on|off  (Bitte nicht stören – optional)
 same => n,Set(CW=${DB(cw/${EXT})})
 same => n,Set(DND=${DB(dnd/${EXT})})
 ; DND sperrt sofort
 same => n,ExecIf($["${DND}"="on"]?Goto(vm,${EXT},1))
 ; Call-Waiting aus: bei INUSE direkt zur Mailbox
 same => n,ExecIf($["${CW}"="off" & "${DEVICE_STATE(SIP/${EXT})}"="INUSE"]?Goto(vm,${EXT},1))
 same => n,Dial(SIP/${EXT},30,rtT)
 same => n,Hangup()

[vm]
exten => _X.,1,NoOp(Voicemail for ${EXTEN})
 same => n,Voicemail(${EXTEN}@default,u)
 same => n,Hangup()
EOFCALLHELP
  fi
}

# Ersetzt die Dial-Zeile im internen Block für EXT durch Local/EXT@calltoext
internal_use_local_helper_for_ext() {
  local ext="$1"
  backup "$EXT_CONF"
  awk -v EXT="$ext" '
  BEGIN{sect=0; inblk=0; replaced=0}
  /^\[internal\]$/ { print; sect=1; next }
  /^\[/ { print; if ($0!="[internal]") { sect=0 }; inblk=0; next }
  {
    if (sect && $0 ~ ("^exten[ \t]*=>[ \t]*"EXT",")) { print; inblk=1; next }
    if (sect && inblk) {
      if ($0 ~ /Dial\(/) {
        print " same => n,Dial(Local/"EXT"@calltoext,30,rtT)"
        replaced=1
        next
      }
    }
    print
  }
  END{
    if (sect && inblk && !replaced) { print " same => n,Dial(Local/"EXT"@calltoext,30,rtT)" }
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ringgroup_get_dial_line() {
  awk '
  BEGIN{inblk=0}
  /^\[ringall\]$/ { inblk=1; next }
  /^\[/ { if (inblk) exit }
  { if (inblk && /Dial\(/) { print; exit } }
  ' "$EXT_CONF"
}

ringgroup_set_members() {
  local members_csv="$1" # "100,101,102"
  local dial_targets=""
  IFS=',' read -ra arr <<< "$members_csv"
  for e in "${arr[@]}"; do
    e="${e//[[:space:]]/}"
    [[ -z "$e" ]] && continue
    if ! grep -q "^\[$e\]" "$SIP_CONF"; then
      echo "Warnung: Nebenstelle $e existiert nicht, wird übersprungen."
      continue
    fi
    ensure_calltoext_helper
    internal_use_local_helper_for_ext "$e"
    if [ -z "$dial_targets" ]; then
      dial_targets="Local/${e}@calltoext"
    else
      dial_targets="${dial_targets}&Local/${e}@calltoext"
    fi
  done
  [ -z "$dial_targets" ] && { echo "Keine gültigen Nebenstellen angegeben."; return 1; }

  backup "$EXT_CONF"
  awk -v NEWDIAL="$dial_targets" '
  BEGIN{inblk=0; done=0}
  /^\[ringall\]$/ { print; inblk=1; next }
  /^\[/ { if (inblk) { inblk=0 } }
  {
    if (inblk && /Dial\(/) { print " same => n,Dial("NEWDIAL",30,rtT)"; done=1; next }
    print
  }
  END{
    if (inblk && !done) { print " same => n,Dial("NEWDIAL",30,rtT)" }
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

cw_set() { local ext="$1" state="$2"; $AST_CLI "database put cw ${ext} ${state}" >/dev/null; }
cw_get() { local ext="$1"; $AST_CLI "database get cw ${ext}" 2>/dev/null | awk -F': ' '/Value/{print $2}'; }

pause() { read -rp "Weiter mit [Enter]..."; }

menu_vm() {
  clear
  echo "Anrufbeantworter (Voicemail) konfigurieren"
  echo "------------------------------------------"
  echo "Nebenstellen:"
  list_extensions | nl -w2 -s'. '
  echo ""
  read -rp "Nebenstelle auswählen (Nummer eingeben): " idx
  local sel_ext sel_name
  sel_ext=$(list_extensions | sed -n "${idx}p" | awk '{print $1}')
  sel_name=$(list_extensions | sed -n "${idx}p" | cut -d' ' -f2-)
  [ -z "$sel_ext" ] && { echo "Ungültige Auswahl."; pause; return; }

  echo "Gewählt: $sel_ext ($sel_name)"
  echo "1) Voicemail einschalten/setzen"
  echo "2) Voicemail ausschalten"
  read -rp "Auswahl: " action

  if [ "$action" = "1" ]; then
    read -rp "PIN (4-6 Stellen) für Mailbox ${sel_ext}: " pin
    [ -z "$pin" ] && { echo "Abgebrochen."; pause; return; }
    add_or_update_vm_entry "$sel_ext" "$pin" "$sel_name"
    sip_set_mailbox "$sel_ext"
    if ! ext_block_has_vmline "$sel_ext"; then
      ext_add_vmline_after_dial "$sel_ext"
    fi
    ensure_calltoext_helper
    internal_use_local_helper_for_ext "$sel_ext"
    reload_asterisk
    echo "Voicemail für ${sel_ext} aktiviert/aktualisiert."
  elif [ "$action" = "2" ]; then
    remove_vm_entry "$sel_ext"
    sip_remove_mailbox "$sel_ext"
    ext_remove_vmline "$sel_ext"
    reload_asterisk
    echo "Voicemail für ${sel_ext} deaktiviert."
  else
    echo "Keine gültige Auswahl."
  fi
  pause
}

menu_ringgroup() {
  clear
  echo "Ringgruppe bearbeiten ([ringall])"
  echo "---------------------------------"
  local cur
  cur="$(ringgroup_get_dial_line)"
  echo "Aktuelle Dial-Zeile:"
  echo "  ${cur:-(keine gesetzt)}"
  echo ""
  echo "Nebenstellenliste (kommasepariert, z.B. 100,101,104):"
  list_extensions | nl -w2 -s'. '
  echo ""
  read -rp "Mitglieder neu setzen: " csv
  [ -z "$csv" ] && { echo "Abgebrochen."; pause; return; }
  ensure_calltoext_helper
  if ringgroup_set_members "$csv"; then
    reload_asterisk
    echo "Ringgruppe aktualisiert."
  else
    echo "Ringgruppe NICHT geändert."
  fi
  pause
}

menu_cw() {
  clear
  echo "Call-Waiting (Klopfen) je Nebenstelle"
  echo "-------------------------------------"
  echo "Aktuelle Werte (cw/<ext> = on|off):"
  echo ""
  while read -r line; do
    ext=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | cut -d' ' -f2-)
    state="$(cw_get "$ext")"
    state="${state:-on}" # Default an
    printf "  %s  %-20s  [%s]\n" "$ext" "$name" "$state"
  done < <(list_extensions)
  echo ""
  echo "1) Für EINE Nebenstelle setzen"
  echo "2) Für ALLE Nebenstellen setzen"
  read -rp "Auswahl: " m

  if [ "$m" = "1" ]; then
    read -rp "Nebenstelle: " ext
    if ! grep -q "^\[$ext\]" "$SIP_CONF"; then echo "Unbekannte Nebenstelle."; pause; return; fi
    read -rp "State (on/off): " st
    [[ "$st" != "on" && "$st" != "off" ]] && { echo "Ungültig."; pause; return; }
    ensure_calltoext_helper
    internal_use_local_helper_for_ext "$ext"
    cw_set "$ext" "$st"
    reload_asterisk
    echo "Call-Waiting für $ext auf $st gesetzt."
  elif [ "$m" = "2" ]; then
    read -rp "State (on/off) für ALLE: " st
    [[ "$st" != "on" && "$st" != "off" ]] && { echo "Ungültig."; pause; return; }
    ensure_calltoext_helper
    while read -r line; do
      ext=$(echo "$line" | awk '{print $1}')
      internal_use_local_helper_for_ext "$ext"
      cw_set "$ext" "$st"
    done < <(list_extensions)
    reload_asterisk
    echo "Call-Waiting global auf $st gesetzt."
  else
    echo "Abbruch."
  fi
  pause
}

menu_main() {
  require_files
  while true; do
    clear
    echo "Asterisk Admin (V7 Post-Install)"
    echo "--------------------------------"
    echo "1) Anrufbeantworter einstellen"
    echo "2) Ringgruppen bearbeiten"
    echo "3) Anrufverhalten: Call-Waiting (Klopfen) ein/aus"
    echo "q) Beenden"
    read -rp "Auswahl: " ans
    case "$ans" in
      1) menu_vm ;;
      2) menu_ringgroup ;;
      3) menu_cw ;;
      q|Q) exit 0 ;;
      *) echo "Ungültig"; sleep 1 ;;
    esac
  done
}

menu_main
