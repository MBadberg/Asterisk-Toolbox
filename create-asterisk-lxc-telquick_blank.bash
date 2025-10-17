#!/bin/bash

#############################################
# Asterisk LXC Container Setup für Proxmox
# Mit tel.quick SIP-Trunk und Grandstream
# Basierend auf wilhelm.tel Konfiguration (V7, angepasst)
#############################################

#==========================================
# PROXMOX KONFIGURATION
#==========================================
PROXMOX_HOST=""
PROXMOX_USER="root"
PROXMOX_PASSWORD=""  

#==========================================
# CONTAINER KONFIGURATION
#==========================================
LXC_ID="200"              # Container ID (anpassen falls bereits vergeben)
LXC_HOSTNAME="asterisk-server"
LXC_MEMORY="2048"         # RAM in MB
LXC_SWAP="512"            # SWAP in MB
LXC_DISK="10"             # Disk-Größe in GB
LXC_CORES="2"             # CPU Kerne
LXC_STORAGE="local-lvm"   # Proxmox Storage
LXC_BRIDGE="vmbr0"        # Netzwerk-Bridge
LXC_IP="dhcp"             # IP-Konfiguration (oder z.B. "192.168.1.100/24")
LXC_GATEWAY=""            # Gateway (leer bei DHCP)

#==========================================
# TEL.QUICK SIP-TRUNK KONFIGURATION
# (Basierend auf wilhelm.tel/tel.quick)
#==========================================
# WICHTIG: Hier Ihre tel.quick Zugangsdaten eintragen!
TRUNK_PHONE_NUMBER=""                    # Ihre Rufnummer (z.B. 040123456)
TRUNK_SIP_USERNAME=""                     # SIP-Benutzername von tel.quick
TRUNK_SIP_PASSWORD=""                      # SIP-Passwort von tel.quick

# tel.quick Server-Konfiguration (aus PDF)
TRUNK_SIP_DOMAIN="voip3.wtnet.de"         # SIP-Domain / From-Domain
TRUNK_SIP_REGISTRAR="voip3.wtnet.de"      # SIP-Registrar (eingehend + Registrierung)
TRUNK_SIP_PROXY="proxy.voipslb.wtnet.de"  # SIP-Outbound-Proxy (FQDN!)
TRUNK_SIP_PORT="5060"                     # SIP-Port

#==========================================
# GRANDSTREAM TELEFONE KONFIGURATION
#==========================================
# Format: "Extension:Passwort:Name"
# Extension sollte 3-4 stellig sein (z.B. 100, 101, 102...)
PHONES=(
    "100:GeheimesPasswort100:Wohnzimmer"
    "101:GeheimesPasswort101:Büro"
    "102:GeheimesPasswort102:Büro_Mitarbeiter1"
    "103:GeheimesPasswort103:Büro_Mitarbeiter2"
    "104:GeheimesPasswort104:Konferenzraum"
)

#==========================================
# ERWEITERTE EINSTELLUNGEN
#==========================================
# Codec-Präferenzen (tel.quick unterstützt G.711 a-law/u-law)
CODECS="alaw,ulaw"  # g729 nur wenn lizenziert

# NAT-Einstellungen
# Falls DynDNS genutzt wird, EXTERNAL_HOST setzen (z.B. palais.srv64.de)
EXTERNAL_HOST=""                      # DynDNS Hostname
EXTERNAL_IP=""                        # statische externe IP (leer lassen, wenn EXTERNAL_HOST genutzt wird)
EXTERNAL_REFRESH="300"                # externhost Refresh-Sekunden (empfohlen 300)

# Mehrere lokale Netze (werden alle eingetragen)
LOCAL_NETWORKS=("192.168.1.0/24" "192.168.7.0/24")

# STUN-Server (optional; externhost/externip sind maßgeblich)
STUN_SERVER="stun.voipslb.wtnet"

# Voicemail aktivieren?
ENABLE_VOICEMAIL="yes"

# Call Recording aktivieren?
ENABLE_RECORDING="no"

#==========================================
# AB HIER NICHTS MEHR ÄNDERN
#==========================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Asterisk LXC mit tel.quick SIP-Trunk (V7 angepasst)${NC}"
echo -e "${GREEN}========================================${NC}"

ssh_exec() { sshpass -p "$PROXMOX_PASSWORD" ssh -o StrictHostKeyChecking=no "${PROXMOX_USER}@${PROXMOX_HOST}" "$1"; }
scp_copy() { sshpass -p "$PROXMOX_PASSWORD" scp -o StrictHostKeyChecking=no "$1" "${PROXMOX_USER}@${PROXMOX_HOST}:$2"; }

if ! command -v sshpass &> /dev/null; then
  echo -e "${RED}Fehler: sshpass ist nicht installiert!${NC}"; exit 1
fi

echo -e "${YELLOW}Validiere Konfiguration...${NC}"
if [ -z "$TRUNK_SIP_USERNAME" ] || [ -z "$TRUNK_SIP_PASSWORD" ] || [ -z "$TRUNK_PHONE_NUMBER" ]; then
  echo -e "${RED}Fehler: tel.quick Zugangsdaten fehlen!${NC}"; exit 1
fi
echo -e "${GREEN}✓ tel.quick Konfiguration vorhanden${NC}"
echo -e "${GREEN}✓ ${#PHONES[@]} Telefon(e) konfiguriert${NC}"

echo -e "${YELLOW}Teste SSH-Verbindung...${NC}"
if ! ssh_exec "echo 'OK'" > /dev/null 2>&1; then echo -e "${RED}Fehler: SSH-Verbindung fehlgeschlagen!${NC}"; exit 1; fi
echo -e "${GREEN}✓ SSH-Verbindung erfolgreich${NC}"

echo -e "${YELLOW}Prüfe Storage '${LXC_STORAGE}'...${NC}"
if ! ssh_exec "pvesm status | grep -q '^${LXC_STORAGE} '"; then
  echo -e "${RED}Bitte passen Sie LXC_STORAGE im Script an!${NC}"; exit 1
fi
echo -e "${GREEN}✓ Storage '${LXC_STORAGE}' verfügbar${NC}"

echo -e "${YELLOW}Prüfe Bridge '${LXC_BRIDGE}'...${NC}"
if ! ssh_exec "ip link show ${LXC_BRIDGE}" > /dev/null 2>&1; then
  echo -e "${RED}Bitte passen Sie LXC_BRIDGE im Script an!${NC}"; exit 1
fi
echo -e "${GREEN}✓ Bridge '${LXC_BRIDGE}' verfügbar${NC}"

echo -e "${YELLOW}Prüfe Container ID ${LXC_ID}...${NC}"
if ssh_exec "pct status ${LXC_ID} 2>/dev/null" > /dev/null 2>&1; then
  echo -e "${RED}Fehler: Container ID ${LXC_ID} existiert bereits!${NC}"; exit 1
fi
echo -e "${GREEN}✓ Container ID ${LXC_ID} ist verfügbar${NC}"

echo -e "${YELLOW}Suche Debian Template...${NC}"
ssh_exec "pveam update" > /dev/null 2>&1
AVAILABLE_TEMPLATES=$(ssh_exec "ls /var/lib/vz/template/cache/debian-12-standard*.tar.zst 2>/dev/null")
if [ -n "$AVAILABLE_TEMPLATES" ]; then
  TEMPLATE_FILE=$(ssh_exec "ls /var/lib/vz/template/cache/debian-12-standard*.tar.zst 2>/dev/null | head -1 | xargs basename")
else
  DEBIAN_TEMPLATE=$(ssh_exec "pveam available | grep 'debian-12-standard' | tail -1 | awk '{print \$2}'")
  ssh_exec "pveam download local ${DEBIAN_TEMPLATE}"
  TEMPLATE_FILE=$(basename "$DEBIAN_TEMPLATE")
fi
LXC_TEMPLATE="local:vztmpl/${TEMPLATE_FILE}"
echo -e "${GREEN}✓ Template: ${TEMPLATE_FILE}${NC}"

echo -e "${YELLOW}Erstelle LXC Container...${NC}"
CREATE_CMD="pct create ${LXC_ID} ${LXC_TEMPLATE} --hostname ${LXC_HOSTNAME} --memory ${LXC_MEMORY} --swap ${LXC_SWAP} --cores ${LXC_CORES} --rootfs ${LXC_STORAGE}:${LXC_DISK} --net0 name=eth0,bridge=${LXC_BRIDGE},ip=${LXC_IP}"
[ -n "$LXC_GATEWAY" ] && CREATE_CMD="${CREATE_CMD},gw=${LXC_GATEWAY}"
CREATE_CMD="${CREATE_CMD} --unprivileged 1 --features nesting=1 --onboot 1"
ssh_exec "$CREATE_CMD" || { echo -e "${RED}Fehler beim Erstellen des Containers!${NC}"; exit 1; }
echo -e "${GREEN}✓ Container erstellt${NC}"

echo -e "${YELLOW}Starte Container...${NC}"
ssh_exec "pct start ${LXC_ID}" 2>/dev/null
sleep 10
echo -e "${GREEN}✓ Container läuft${NC}"

echo -e "${YELLOW}Erstelle Asterisk Installations-Script...${NC}"

cat > /tmp/install_asterisk.sh << 'EOFMAIN'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
echo "Asterisk Installation..."

apt-get update
apt-get upgrade -y
apt-get install -y wget build-essential libncurses5-dev libssl-dev libxml2-dev \
  libsqlite3-dev uuid-dev libjansson-dev libedit-dev curl git pkg-config autoconf \
  automake libtool subversion dnsutils

cd /usr/src
ASTERISK_VERSION=$(curl -s https://downloads.asterisk.org/pub/telephony/asterisk/ | grep -oP 'asterisk-20\.\d+\.\d+\.tar\.gz' | sort -V | tail -1 | sed 's/asterisk-//;s/.tar.gz//')
[ -z "$ASTERISK_VERSION" ] && ASTERISK_VERSION="20.10.0"
wget -q https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-${ASTERISK_VERSION}.tar.gz || true
[ ! -f "asterisk-${ASTERISK_VERSION}.tar.gz" ] && wget -q https://downloads.asterisk.org/pub/telephony/certified-asterisk/asterisk-20.7-cert2.tar.gz && mv asterisk-20.7-cert2.tar.gz asterisk-${ASTERISK_VERSION}.tar.gz
[ ! -f "asterisk-${ASTERISK_VERSION}.tar.gz" ] && { echo "Download fehlgeschlagen"; exit 1; }
tar xzf asterisk-${ASTERISK_VERSION}.tar.gz && cd asterisk-${ASTERISK_VERSION}

contrib/scripts/get_mp3_source.sh || true
contrib/scripts/install_prereq install <<EOF
yes
EOF

./configure --with-jansson-bundled --with-pjproject-bundled
make menuselect.makeopts
menuselect/menuselect \
  --enable chan_sip \
  --enable app_dial --enable app_voicemail --enable app_echo --enable app_playback \
  --enable res_rtp_asterisk \
  --enable codec_alaw --enable codec_ulaw --enable codec_gsm \
  --enable format_wav --enable format_pcm --enable format_gsm \
  --enable pbx_config --enable cdr_csv \
  --disable BUILD_NATIVE \
  menuselect.makeopts || true

make -j"$(nproc)"
make install
make samples
make config

groupadd asterisk 2>/dev/null || true
useradd -r -d /var/lib/asterisk -g asterisk asterisk 2>/dev/null || true
usermod -aG audio,dialout asterisk
mkdir -p /run/asterisk /var/run/asterisk
chown -R asterisk:asterisk /etc/asterisk /var/{lib,log,spool}/asterisk /usr/lib/asterisk /run/asterisk /var/run/asterisk

cat > /etc/asterisk/modules.conf <<'EOFMC'
[modules]
autoload=yes
noload => res_pjsip.so
noload => res_pjsip_session.so
noload => res_pjsip_outbound_registration.so
noload => res_pjsip_outbound_publish.so
noload => res_pjsip_registrar.so
noload => res_pjsip_pubsub.so
noload => res_pjsip_publish_asterisk.so
noload => res_pjsip_pidf_body_generator.so
noload => res_pjsip_mwi.so
noload => res_pjsip_mwi_body_generator.so
noload => res_pjsip_dlg_options.so
noload => res_pjsip_logger.so
noload => res_pjsip_notify.so
noload => res_pjsip_phoneprov_provider.so
noload => res_pjsip_transport_websocket.so
load => chan_sip.so
EOFMC

cat > /etc/tmpfiles.d/asterisk.conf << 'EOFTMP'
d /run/asterisk 0755 asterisk asterisk -
EOFTMP
systemd-tmpfiles --create /etc/tmpfiles.d/asterisk.conf || true

# sip.conf
cp -a /etc/asterisk/sip.conf /etc/asterisk/sip.conf.orig || true
cat > /etc/asterisk/sip.conf << 'EOFSIP'
[general]
context=default
allowguest=no
allowoverlap=no
bindport=5060
bindaddr=0.0.0.0
udpbindaddr=0.0.0.0:5060
tcpenable=no

; DNS & SRV
srvlookup=yes
dnsmgr=yes

; RPID/PAI
trustrpid=yes
sendrpid=pai

; STUN optional
stunaddr=STUN_SERVER_PLACEHOLDER

; NAT
nat=force_rport,comedia
externrefresh=10
qualify=yes
qualifyfreq=60

; RTP (Deckel für ~50 Calls)
rtpstart=10000
rtpend=10300

; Codecs
disallow=all
allow=CODECS_PLACEHOLDER

language=de

; Registrierung
register => TRUNK_USERNAME_PLACEHOLDER:TRUNK_PASSWORD_PLACEHOLDER@TRUNK_REGISTRAR_PLACEHOLDER/TRUNK_NUMBER_PLACEHOLDER

;==========================================
; TEL.QUICK SIP-TRUNK (chan_sip)
;==========================================
[telquick-out]
type=peer
host=TRUNK_REGISTRAR_PLACEHOLDER
defaultuser=TRUNK_USERNAME_PLACEHOLDER
secret=TRUNK_PASSWORD_PLACEHOLDER
fromuser=TRUNK_USERNAME_PLACEHOLDER
authuser=TRUNK_USERNAME_PLACEHOLDER
fromdomain=TRUNK_DOMAIN_PLACEHOLDER
insecure=port,invite
context=from-trunk
canreinvite=no
dtmfmode=rfc2833
disallow=all
allow=CODECS_PLACEHOLDER
nat=force_rport,comedia
qualify=no
sendrpid=pai
trustrpid=yes
; Outbound-Proxy korrekt (kein "sip:" Präfix), Port separat
outboundproxy=TRUNK_PROXY_PLACEHOLDER
outboundproxyport=TRUNK_PORT_PLACEHOLDER
EOFSIP

# extensions.conf
cp -a /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.orig || true
cat > /etc/asterisk/extensions.conf << 'EOFEXTENSIONS'
[general]
static=yes
writeprotect=no
autofallthrough=yes

[globals]
TRUNK=telquick-out
TRUNK_NUMBER=TRUNK_NUMBER_PLACEHOLDER

; Eingehend – DID auf Ringgruppe
[from-trunk]
exten => TRUNK_NUMBER_PLACEHOLDER,1,NoOp(Eingehend für TRUNK_NUMBER_PLACEHOLDER von ${CALLERID(all)})
 same => n,Goto(ringall,s,1)
exten => _X.,1,Goto(ringall,s,1)

; Interne Nebenstellen
[internal]
; Normalisierung für ausgehend
exten => _+49X.,1,NoOp(Normalize +49 to 0: ${EXTEN})
 same => n,Set(NORM=0${EXTEN:3})
 same => n,Goto(outbound,${NORM},1)

exten => _49X.,1,NoOp(Normalize 49 to 0: ${EXTEN})
 same => n,Set(NORM=0${EXTEN:2})
 same => n,Goto(outbound,${NORM},1)

exten => _+X.,1,NoOp(Normalize + to 00: ${EXTEN})
 same => n,Set(NORM=00${EXTEN:1})
 same => n,Goto(outbound,${NORM},1)

include => outbound

[outbound]
; Mobil
exten => _01[5-7]XXXXXXXXX,1,NoOp(Mobil: ${EXTEN})
 same => n,Set(CALLERID(num)=${TRUNK_NUMBER})
 same => n,Dial(SIP/${TRUNK}/${EXTEN},60,rtT)
 same => n,Hangup()

; Festnetz
exten => _0XXXXXXXXX.,1,NoOp(Festnetz: ${EXTEN})
 same => n,Set(CALLERID(num)=${TRUNK_NUMBER})
 same => n,Dial(SIP/${TRUNK}/${EXTEN},60,rtT)
 same => n,Hangup()

; International
exten => _00X.,1,NoOp(International: ${EXTEN})
 same => n,Set(CALLERID(num)=${TRUNK_NUMBER})
 same => n,Dial(SIP/${TRUNK}/${EXTEN},60,rtT)
 same => n,Hangup()

; Notruf
exten => 110,1,NoOp(NOTRUF POLIZEI)
 same => n,Dial(SIP/${TRUNK}/110)
 same => n,Hangup()

exten => 112,1,NoOp(NOTRUF FEUERWEHR)
 same => n,Dial(SIP/${TRUNK}/112)
 same => n,Hangup()

; Tests
exten => *600,1,Answer()
 same => n,Wait(1)
 same => n,Playback(demo-echotest)
 same => n,Echo()
 same => n,Hangup()

exten => *601,1,Answer()
 same => n,Wait(1)
 same => n,Playback(demo-congrats)
 same => n,Hangup()

exten => *99,1,Answer()
 same => n,Wait(1)
 same => n,VoiceMailMain(${CALLERID(num)}@default)
 same => n,Hangup()

exten => *90,1,Answer()
 same => n,Playback(hello-world)
 same => n,SayDigits(${CALLERID(num)})
 same => n,Hangup()
EOFEXTENSIONS

# rtp.conf (Range für ~50 gleichzeitige Gespräche)
cat > /etc/asterisk/rtp.conf << 'EOFRTPCONF'
[general]
rtpstart=10000
rtpend=10300
rtpchecksums=yes
dtmftimeout=3000
EOFRTPCONF

# Registry-Wrapper
cat > /usr/local/bin/asterisk-show-registry << 'EOFREG'
#!/bin/bash
set -e
OUT_PJ=$(asterisk -rx "pjsip show registrations" 2>&1 || true)
if ! echo "$OUT_PJ" | grep -qiE "No such command|Unknown command"; then
  echo "$OUT_PJ"
  if echo "$OUT_PJ" | grep -qi "No objects found"; then
    echo ""
    echo "---- chan_sip (Fallback) ----"
    asterisk -rx "sip show registry" 2>&1 || true
  fi
  exit 0
fi
asterisk -rx "sip show registry" 2>&1 || true
EOFREG
chmod +x /usr/local/bin/asterisk-show-registry

EOFMAIN

# Platzhalter ersetzen (KEIN /etc/asterISK Tippfehler)
cat >> /tmp/install_asterisk.sh << EOFVARS
sed -i "s|STUN_SERVER_PLACEHOLDER|${STUN_SERVER}|g" /etc/asterisk/sip.conf
sed -i "s|CODECS_PLACEHOLDER|${CODECS}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_USERNAME_PLACEHOLDER|${TRUNK_SIP_USERNAME}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_PASSWORD_PLACEHOLDER|${TRUNK_SIP_PASSWORD}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_REGISTRAR_PLACEHOLDER|${TRUNK_SIP_REGISTRAR}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_DOMAIN_PLACEHOLDER|${TRUNK_SIP_DOMAIN}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_PROXY_PLACEHOLDER|${TRUNK_SIP_PROXY}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_PORT_PLACEHOLDER|${TRUNK_SIP_PORT}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_NUMBER_PLACEHOLDER|${TRUNK_PHONE_NUMBER}|g" /etc/asterisk/sip.conf
sed -i "s|TRUNK_NUMBER_PLACEHOLDER|${TRUNK_PHONE_NUMBER}|g" /etc/asterisk/extensions.conf
EOFVARS

# NAT-/DynDNS-/Localnet-Block: alte NAT-Zeilen entfernen, externhost/externip + mehrere localnets setzen
cat >> /tmp/install_asterisk.sh << 'EOFNAT'
# Bereinigen
sed -i '/^[[:space:]]*externip[[:space:]]*=/d' /etc/asterisk/sip.conf
sed -i '/^[[:space:]]*externhost[[:space:]]*=/d' /etc/asterisk/sip.conf
sed -i '/^[[:space:]]*externrefresh[[:space:]]*=/d' /etc/asterisk/sip.conf
sed -i '/^[[:space:]]*localnet[[:space:]]*=/d' /etc/asterisk/sip.conf

# externhost / externip
EOFNAT

if [ -n "$EXTERNAL_HOST" ]; then
cat >> /tmp/install_asterisk.sh << EOFNAT_HOST
sed -i '/^\\[general\\]/a externrefresh=${EXTERNAL_REFRESH}' /etc/asterisk/sip.conf
sed -i '/^\\[general\\]/a externhost=${EXTERNAL_HOST}' /etc/asterisk/sip.conf
EOFNAT_HOST
elif [ -n "$EXTERNAL_IP" ]; then
cat >> /tmp/install_asterisk.sh << EOFNAT_IP
sed -i '/^\\[general\\]/a externip=${EXTERNAL_IP}' /etc/asterisk/sip.conf
EOFNAT_IP
else
cat >> /tmp/install_asterisk.sh << 'EOFNAT_AUTO'
PUBIP=$(curl -s https://ifconfig.me || dig -4 +short myip.opendns.com @resolver1.opendns.com)
[ -n "$PUBIP" ] && sed -i "/^\\[general\\]/a externip=${PUBIP}" /etc/asterisk/sip.conf
EOFNAT_AUTO
fi

# Localnets in einem Schritt einfügen
{
  echo "awk 'BEGIN{done=0} {print} /^\\[general\\]/{ if(!done){"
  for LN in "${LOCAL_NETWORKS[@]}"; do
    printf "print \"localnet=%s\"\n" "$LN"
  done
  echo "done=1} }' /etc/asterisk/sip.conf > /etc/asterisk/sip.conf.new && mv /etc/asterisk/sip.conf.new /etc/asterisk/sip.conf"
} >> /tmp/install_asterisk.sh

# Grandstream-Nebenstellen
cat >> /tmp/install_asterisk.sh << 'EOFPHONES'
echo "" >> /etc/asterisk/sip.conf
echo ";==========================================" >> /etc/asterisk/sip.conf
echo "; GRANDSTREAM TELEFONE" >> /etc/asterisk/sip.conf
echo ";==========================================" >> /etc/asterisk/sip.conf
EOFPHONES

for phone in "${PHONES[@]}"; do
  IFS=':' read -r ext password name <<< "$phone"
  cat >> /tmp/install_asterisk.sh << EOFPHONE
cat >> /etc/asterisk/sip.conf << 'EOFEXT'
[${ext}]
type=friend
secret=${password}
host=dynamic
context=internal
callerid="${name}" <${ext}>
disallow=all
allow=${CODECS}
nat=force_rport,comedia
qualify=yes
dtmfmode=rfc2833
canreinvite=no
directmedia=no
$(if [ "$ENABLE_VOICEMAIL" == "yes" ]; then echo "mailbox=${ext}@default"; fi)
EOFEXT

cat >> /etc/asterisk/extensions.conf << 'EOFINT'
; ${name}
[internal]
exten => ${ext},1,NoOp(Anruf an ${name})
 same => n,Dial(SIP/${ext},30,rtT)
$(if [ "$ENABLE_VOICEMAIL" == "yes" ]; then echo " same => n,Voicemail(${ext}@default,u)"; else echo " ; same => n,Hangup()"; fi)
 same => n,Hangup()
EOFINT
EOFPHONE
done

# Ringgruppe [ringall]
RG=""; FIRST_EXT=""
for phone in "${PHONES[@]}"]; do :; done
for phone in "${PHONES[@]}"; do
  IFS=':' read -r ext password name <<< "$phone"
  [ -z "$FIRST_EXT" ] && FIRST_EXT="$ext"
  if [ -z "$RG" ]; then RG="SIP/${ext}"; else RG="${RG}&SIP/${ext}"; fi
done
cat >> /tmp/install_asterisk.sh << EOFRING
cat >> /etc/asterisk/extensions.conf << 'EOFRINGCONF'
[ringall]
exten => s,1,NoOp(Ringgruppe alle)
 same => n,Answer()
 same => n,Dial(${RG},30,rtT)
$(if [ "$ENABLE_VOICEMAIL" == "yes" ]; then echo " same => n,Voicemail(${FIRST_EXT}@default,u)"; else echo " ; same => n,Hangup()"; fi)
 same => n,Hangup()
EOFRINGCONF
EOFRING

# Start / Firewall
cat >> /tmp/install_asterisk.sh << 'EOFSTART'
chown -R asterisk:asterisk /etc/asterisk /var/{lib,log,spool}/asterisk /usr/lib/asterisk /run/asterisk /var/run/asterisk || true
chmod 0755 /run/asterisk /var/run/asterisk || true
systemctl daemon-reload
systemctl enable asterisk || true
systemctl restart asterisk || true

sleep 5
systemctl is-active --quiet asterisk || { systemctl status asterisk --no-pager || true; exit 1; }

if command -v ufw &> /dev/null; then
  ufw allow 5060/udp comment 'Asterisk SIP'
  ufw allow 5060/tcp comment 'Asterisk SIP'
  ufw allow 10000:10300/udp comment 'Asterisk RTP (50 calls)'
fi
EOFSTART

# Doku
cat >> /tmp/install_asterisk.sh << 'EOFDOC'
cat > /root/asterisk-config.txt << 'EOFDOCEND'
========================================
ASTERISK MIT TEL.QUICK KONFIGURATION
========================================
TEL.QUICK TRUNK:
- Rufnummer: TRUNK_NUMBER_PLACEHOLDER
- SIP-Domain: TRUNK_DOMAIN_PLACEHOLDER
- SIP-Registrar: TRUNK_REGISTRAR_PLACEHOLDER
- SIP-Proxy: TRUNK_PROXY_PLACEHOLDER
- Username: TRUNK_USERNAME_PLACEHOLDER

GRANDSTREAM TELEFONE:
EOFDOCEND
EOFDOC

for phone in "${PHONES[@]}"; do
  IFS=':' read -r ext password name <<< "$phone"
  cat >> /tmp/install_asterisk.sh << EOFDOC2
cat >> /root/asterisk-config.txt << 'EOFDOCEXT'
${name}:
- Extension: ${ext}
- Passwort: ${password}
- SIP-Server: \$(hostname -I | awk '{print \$1}')
- Port: 5060
EOFDOCEXT
EOFDOC2
done

cat >> /tmp/install_asterisk.sh << 'EOFDOCFINAL'
cat >> /root/asterisk-config.txt << 'EOFDOCEND2'

WICHTIGE BEFEHLE:
- Asterisk CLI: asterisk -rvvv
- SIP Registrierung (auto + Fallback): /usr/local/bin/asterisk-show-registry
- SIP Peers (chan_sip): asterisk -rx "sip show peers"
- Neustart: systemctl restart asterisk
- Logs: tail -f /var/log/asterisk/messages

========================================
EOFDOCEND2

sed -i "s|TRUNK_NUMBER_PLACEHOLDER|'"${TRUNK_PHONE_NUMBER}"'|g" /root/asterisk-config.txt
sed -i "s|TRUNK_DOMAIN_PLACEHOLDER|'"${TRUNK_SIP_DOMAIN}"'|g" /root/asterisk-config.txt
sed -i "s|TRUNK_REGISTRAR_PLACEHOLDER|'"${TRUNK_SIP_REGISTRAR}"'|g" /root/asterisk-config.txt
sed -i "s|TRUNK_PROXY_PLACEHOLDER|'"${TRUNK_SIP_PROXY}"'|g" /root/asterisk-config.txt
sed -i "s|TRUNK_USERNAME_PLACEHOLDER|'"${TRUNK_SIP_USERNAME}"'|g" /root/asterisk-config.txt

echo "========================================="
echo "INSTALLATION ABGESCHLOSSEN!"
echo "========================================="
cat /root/asterisk-config.txt
EOFDOCFINAL

# Übertragen und ausführen
scp_copy /tmp/install_asterisk.sh /tmp/install_asterisk_${LXC_ID}.sh
ssh_exec "pct push ${LXC_ID} /tmp/install_asterisk_${LXC_ID}.sh /tmp/install_asterisk.sh"
ssh_exec "pct exec ${LXC_ID} -- chmod +x /tmp/install_asterisk.sh"
echo -e "${YELLOW}Installiere Asterisk (Kompilierung kann 15-30 Minuten dauern)...${NC}"
ssh_exec "pct exec ${LXC_ID} -- bash /tmp/install_asterisk.sh"

CONTAINER_IP=$(ssh_exec "pct exec ${LXC_ID} -- hostname -I | awk '{print \$1}'")

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}INSTALLATION ERFOLGREICH!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "${BLUE}Container:${NC}"
echo -e "  IP: ${CONTAINER_IP}"
echo -e "  ID: ${LXC_ID}"
echo -e ""
echo -e "${BLUE}tel.quick Trunk:${NC}"
echo -e "  Rufnummer: ${TRUNK_PHONE_NUMBER}"
echo -e "  Registrar: ${TRUNK_SIP_REGISTRAR}"
echo -e "  Proxy:     ${TRUNK_SIP_PROXY}"
echo -e ""
echo -e "${BLUE}Nächste Schritte:${NC}"
echo -e "  1. Telefone auf SIP-Server ${YELLOW}${CONTAINER_IP}${NC} konfigurieren."
echo -e "  2. Test eingehend/ausgehend. Bei DynDNS kann Externaddr bis zu ${EXTERNAL_REFRESH}s benötigen."
echo -e ""
echo -e "${GREEN}========================================${NC}"