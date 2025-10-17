#!/usr/bin/env bash
set -euo pipefail

# Asterisk Admin Menüs für Anpassungen nach der Grundinstallation (V7)
# - Voicemail je Nebenstelle ein/aus
# - Ringgruppen bearbeiten
# - Call-Waiting (Klopfen) je Nebenstelle ein/aus via AstDB
#
# Ausführung direkt im LXC-Container als root:
#   chmod +x asterisk-admin.sh
#   ./asterisk-admin.sh

SIP_CONF="/etc/asterisk/sip.conf"
EXT_CONF="/etc/asterisk/extensions.conf"
VM_CONF="/etc/asterisk/voicemail.conf"
AST_CLI="asterisk -rx"

ts() { date +"%Y%m%d-%H%M%S"; }
backup() {
  local f="$1"
  [ -f "$f" ] && cp -a "$f" "${f}.bak.$(ts)"
}

require_files() {
  for f in "$SIP_CONF" "$EXT_CONF"; do
    if [ ! -f "$f" ]; then
      echo "Fehlt: $f – bitte prüfe deine Installation."
      exit 1
    fi
  done
}

reload_asterisk() {
  $AST_CLI "dialplan reload" >/dev/null 2>&1 || true
  $AST_CLI "sip reload" >/dev/null 2>&1 || true
}

list_extensions() {
  # Liefert "ext name" pro Zeile; Name aus callerid-Attribut, sonst "-"
  awk '
    BEGIN{ext="";name="-";in=0}
    /^\[[0-9]{2,4}\]$/ { if(in && ext!=""){print ext " " name}; ext=gensub(/^\[|\]$/,"","g"); name="-"; in=1; next }
    /^\[/ { if(in && ext!=""){print ext " " name}; in=0; ext=""; name="-"; next }
    in && $0 ~ /^[[:space:]]*type[[:space:]]*=[[:space:]]*friend/ { in=1 }
    in && $0 ~ /^[[:space:]]*host[[:space:]]*=[[:space:]]*dynamic/ { in=1 }
    in && $0 ~ /^[[:space:]]*callerid[[:space:]]*=/ {
      match($0,/callerid[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*<([0-9]+)>/,m);
      if(m[1]!=""){name=m[1]}
    }
    END{ if(in && ext!=""){print ext " " name} }
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
  if ! grep -q '^\[default\]' "$VM_CONF"; then
    echo "" >> "$VM_CONF"
    echo "[default]" >> "$VM_CONF"
  fi
}

vm_entry_exists() {
  local ext="$1"
  grep -Eq "^[[:space:]]*${ext}[[:space:]]*=>" "$VM_CONF"
}

add_or_update_vm_entry() {
  local ext="$1" pin="$2" name="$3"
  ensure_vm_conf
  backup "$VM_CONF"
  if vm_entry_exists "$ext"; then
    # update Zeile (PIN/Name)
    sed -i -E "s|^[[:space:]]*${ext}[[:space:]]*=>.*|${ext} => ${pin},${name},,|g" "$VM_CONF"
  else
    echo "${ext} => ${pin},${name},," >> "$VM_CONF"
  fi
}

remove_vm_entry() {
  local ext="$1"
  backup "$VM_CONF"
  sed -i -E "/^[[:space:]]*${ext}[[:space:]]*=>/d" "$VM_CONF" || true
}

sip_set_mailbox() {
  local ext="$1"
  # mailbox=ext@default im Peer-Block hinzufügen, wenn nicht vorhanden
  backup "$SIP_CONF"
  awk -v EXT="$ext" '
  BEGIN{in=0; have=0}
  {
    if ($0 ~ ("^\\["EXT"\\]$")) {print; in=1; have=0; next}
    if (in && $0 ~ /^\\[/) { if (!have) print "mailbox="EXT"@default"; in=0 }
    if (in && $0 ~ /^[[:space:]]*mailbox[[:space:]]*=/) { print "mailbox="EXT"@default"; have=1; next }
    print
  }
  END{ if (in && !have) print "mailbox="EXT"@default" }
  ' "$SIP_CONF" > "${SIP_CONF}.new" && mv "${SIP_CONF}.new" "$SIP_CONF"
}

sip_remove_mailbox() {
  local ext="$1"
  backup "$SIP_CONF"
  awk -v EXT="$ext" '
  BEGIN{in=0}
  {
    if ($0 ~ ("^\\["EXT"\\]$")) {print; in=1; next}
    if (in && $0 ~ /^\\[/) {in=0}
    if (in && $0 ~ /^[[:space:]]*mailbox[[:space:]]*=/) {next}
    print
  }
  ' "$SIP_CONF" > "${SIP_CONF}.new" && mv "${SIP_CONF}.new" "$SIP_CONF"
}

ext_block_has_vmline() {
  local ext="$1"
  awk -v EXT="$ext" '
  BEGIN{in=0;have=0}
  $0 ~ ("^\\[internal\\]$"){sect=1; next}
  $0 ~ /^\[/{ if (sect && in) exit; if ($0=="[internal]") sect=1; else sect=0; in=0}
  sect && $0 ~ ("^exten[[:space:]]*=>[[:space:]]*"EXT","){in=1}
  in && $0 ~ /Voicemail\(/ {have=1}
  END{ if(have) exit 0; else exit 1 }
  ' "$EXT_CONF"
}

ext_add_vmline_after_dial() {
  local ext="$1"
  backup "$EXT_CONF"
  awk -v EXT="$ext" '
  BEGIN{in=0; added=0}
  {
    if ($0 ~ /^\[internal\]$/){print; sect=1; next}
    if ($0 ~ /^\[/){ if(sect && in && !added){print " same => n,Voicemail("EXT"@default,u)"; added=1} print; if($0!="[internal]") sect=0; in=0; next}
    if (sect && $0 ~ ("^exten[[:space:]]*=>[[:space:]]*"EXT",")) {print; in=1; next}
    if (sect && in && $0 ~ /Dial\(/) {print; if(!added){print " same => n,Voicemail("EXT"@default,u)"; added=1}; next}
    print
  }
  END{ if(sect && in && !added) print " same => n,Voicemail("EXT"@default,u)" }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ext_remove_vmline() {
  local ext="$1"
  backup "$EXT_CONF"
  awk -v EXT="$ext" '
  BEGIN{sect=0; in=0}
  {
    if ($0 ~ /^\[internal\]$/){print; sect=1; next}
    if ($0 ~ /^\[/){ print; if($0!="[internal]") sect=0; in=0; next}
    if (sect && $0 ~ ("^exten[[:space:]]*=>[[:space:]]*"EXT",")) {print; in=1; next}
    if (sect && in && $0 ~ /Voicemail\(/) { next }
    print
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ensure_calltoext_helper() {
  # Fügt [calltoext] + [vm] ein, falls nicht vorhanden
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

internal_use_local_helper_for_ext() {
  local ext="$1"
  backup "$EXT_CONF"
  # Ersetze Dial(SIP/<ext>,...) -> Dial(Local/<ext>@calltoext,30,rtT)
  awk -v EXT="$ext" '
  BEGIN{sect=0; in=0}
  {
    if ($0 ~ /^\[internal\]$/){print; sect=1; next}
    if ($0 ~ /^\[/){ print; if($0!="[internal]") sect=0; in=0; next}
    if (sect && $0 ~ ("^exten[[:space:]]*=>[[:space:]]*"EXT",")) {print; in=1; next}
    if (sect && in && $0 ~ /Dial\(/) {
      gsub(/Dial\\(SIP\\/[0-9]+,.*\\)/, "Dial(Local/"EXT"@calltoext,30,rtT)")
      print; next
    }
    print
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

ringgroup_get_dial_line() {
  awk '
  BEGIN{in=0}
  /^\[ringall\]$/ {in=1; next}
  /^\[/ { if(in) exit }
  in && $0 ~ /Dial\(/ {print; exit}
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
    # Stelle sicher, dass interne Wahl auch Helper nutzt
    internal_use_local_helper_for_ext "$e"
    if [ -z "$dial_targets" ]; then
      dial_targets="Local/${e}@calltoext"
    else
      dial_targets="${dial_targets}&Local/${e}@calltoext"
    fi
  done
  [ -z "$dial_targets" ] && { echo "Keine gültigen Nebenstellen angegeben."; return 1; }

  backup "$EXT_CONF"
  # Ersetze die Dial-Zeile in [ringall]
  awk -v NEWDIAL="$dial_targets" '
  BEGIN{in=0; done=0}
  {
    if ($0 ~ /^\[ringall\]$/){print; in=1; next}
    if (in && $0 ~ /^\[/) {in=0}
    if (in && $0 ~ /Dial\(/) {
      print " same => n,Dial("NEWDIAL",30,rtT)"; done=1; next
    }
    print
  }
  END{
    # Falls keine Dial-Zeile existierte, fügen wir eine hinzu
    if(in && !done){
      print " same => n,Dial("NEWDIAL",30,rtT)"
    }
  }
  ' "$EXT_CONF" > "${EXT_CONF}.new" && mv "${EXT_CONF}.new" "$EXT_CONF"
}

cw_set() {
  local ext="$1" state="$2" # on|off
  $AST_CLI "database put cw ${ext} ${state}" >/dev/null
}

cw_get() {
  local ext="$1"
  $AST_CLI "database get cw ${ext}" 2>/dev/null | awk -F': ' '/Value/{print $2}'
}

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
    # Sicherstellen, dass im internen Block eine Voicemail-Zeile vorhanden ist
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