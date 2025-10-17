# Asterisk-Toolbox

Eine Sammlung nützlicher Skripte rund um Asterisk.

## Übersicht

Diese Toolbox enthält verschiedene Skripte zur Automatisierung und Vereinfachung von Asterisk-Deployments und -Konfigurationen.

---

## Verfügbare Skripte

### 1. create-asterisk-lxc-telquick.sh

**Beschreibung:**  
Dieses Skript automatisiert die vollständige Installation und Konfiguration eines Asterisk-Servers in einem LXC-Container auf Proxmox. Es ist speziell für die Verwendung mit tel.quick (wilhelm.tel) SIP-Trunk und Grandstream-Telefonen optimiert.

**Hauptfunktionen:**
- Automatische Erstellung eines LXC-Containers auf Proxmox
- Installation von Asterisk 20.x aus dem Quellcode
- Vorkonfiguration für tel.quick SIP-Trunk (basierend auf wilhelm.tel Konfiguration)
- Automatische Einrichtung mehrerer Grandstream-Telefone als Nebenstellen
- NAT-/DynDNS-Unterstützung mit externen IPs oder Hostnamen
- Konfiguration von RTP-Ports für bis zu 50 gleichzeitige Anrufe
- Automatische Firewall-Konfiguration (UFW)
- Voicemail-Unterstützung (optional)
- Ringgruppen-Funktion (alle Telefone klingeln bei eingehenden Anrufen)

**Voraussetzungen:**
- Proxmox VE Server mit SSH-Zugang
- `sshpass` auf dem ausführenden System installiert
- tel.quick SIP-Trunk Zugangsdaten (SIP-Benutzername, Passwort, Rufnummer)
- Verfügbare Container-ID und ausreichend Speicherplatz

**⚠️ Sicherheitshinweis:**
- Verwenden Sie starke, einzigartige Passwörter für alle Konfigurationen
- Schützen Sie das Skript vor unbefugtem Zugriff (Dateiberechtigungen: `chmod 600`)
- Erwägen Sie die Verwendung von SSH-Schlüsseln statt Passwörtern für Proxmox
- Die im Skript gezeigten Passwörter sind nur Beispiele und müssen durch sichere Passwörter ersetzt werden

**Konfiguration:**

Vor der Ausführung müssen folgende Variablen im Skript angepasst werden:

**Proxmox-Konfiguration:**
```bash
PROXMOX_HOST=""           # IP oder Hostname des Proxmox-Servers
PROXMOX_USER="root"       # Proxmox SSH-Benutzer
PROXMOX_PASSWORD=""       # SSH-Passwort
```

**Container-Konfiguration:**
```bash
LXC_ID="200"              # Container ID
LXC_HOSTNAME="asterisk-server"
LXC_MEMORY="2048"         # RAM in MB
LXC_SWAP="512"            # SWAP in MB
LXC_DISK="10"             # Disk-Größe in GB
LXC_CORES="2"             # CPU Kerne
LXC_STORAGE="local-lvm"   # Proxmox Storage
LXC_BRIDGE="vmbr0"        # Netzwerk-Bridge
LXC_IP="dhcp"             # IP-Konfiguration
```

**tel.quick SIP-Trunk:**
```bash
TRUNK_PHONE_NUMBER=""     # Ihre tel.quick Rufnummer (z.B. 040123456)
TRUNK_SIP_USERNAME=""     # SIP-Benutzername
TRUNK_SIP_PASSWORD=""     # SIP-Passwort
```

**Telefone:**
```bash
PHONES=(
    "100:GeheimesPasswort100:Wohnzimmer"
    "101:GeheimesPasswort101:Büro"
    # Format: "Extension:Passwort:Name"
)
```

**NAT/DynDNS:**
```bash
EXTERNAL_HOST=""          # DynDNS Hostname (optional)
EXTERNAL_IP=""            # Statische externe IP (optional)
LOCAL_NETWORKS=("192.168.1.0/24" "192.168.7.0/24")  # Lokale Netze
```

**Verwendung:**

1. Skript herunterladen und Konfigurationsvariablen anpassen
2. Ausführbar machen:
   ```bash
   chmod +x create-asterisk-lxc-telquick.sh
   ```
3. Ausführen:
   ```bash
   ./create-asterisk-lxc-telquick.sh
   ```

**Hinweise:**
- Die Kompilierung von Asterisk dauert ca. 15-30 Minuten
- Nach der Installation wird eine Konfigurationsdatei unter `/root/asterisk-config.txt` im Container erstellt
- Das Skript verwendet chan_sip (nicht PJSIP) für maximale Kompatibilität mit tel.quick
- Bei Verwendung von DynDNS kann die externe Adresserkennung bis zu 5 Minuten dauern

**Wichtige Befehle nach der Installation:**
```bash
# Asterisk CLI öffnen
pct exec <LXC_ID> -- asterisk -rvvv

# SIP-Registrierung prüfen
pct exec <LXC_ID> -- /usr/local/bin/asterisk-show-registry

# SIP-Peers anzeigen
pct exec <LXC_ID> -- asterisk -rx "sip show peers"

# Logs anzeigen
pct exec <LXC_ID> -- tail -f /var/log/asterisk/messages
```

**Funktionen:**
- **Eingehende Anrufe:** Alle konfigurierten Telefone klingeln gleichzeitig (Ringgruppe)
- **Ausgehende Anrufe:** Normalisierung von verschiedenen Rufnummernformaten (+49, 49, 0)
- **Interne Gespräche:** Direktwahl zwischen allen Nebenstellen
- **Notruf:** 110 und 112 sind konfiguriert
- **Testfunktionen:**
  - `*600`: Echo-Test
  - `*601`: Ansagetest
  - `*99`: Voicemail-Abfrage
  - `*90`: Sprachtest mit Ziffernansage

---

## Lizenz

Dieses Projekt steht zur freien Verfügung.

## Beiträge

Beiträge sind willkommen! Bitte öffnen Sie ein Issue oder einen Pull Request.
