# IPv64 DynDNS Update – Setup Dokumentation

**Host:** raspberry3b  
**Domain:** rolandb.ipv64.de  
**Interface:** eth0  
**OS:** Ubuntu (NetworkManager)

---

## Übersicht

Automatisches IPv6 DynDNS Update für IPv64.net via Bash-Script mit zwei Auslösern:

1. **NetworkManager Dispatcher** → sofort bei IPv6-Änderung (z.B. neuer Präfix vom ISP)
2. **systemd-Timer** → alle 5 Minuten als Fallback

Das Script liest die öffentliche IPv6-Adresse direkt vom Interface (kein externer Webcheck),
vergleicht sie mit dem aktuellen DNS-Eintrag via `dig` direkt am IPv64-Nameserver
und sendet nur bei Abweichung ein Update.

**Logrotate** rotiert die Logdatei täglich und behält 14 Tage.

---

## Dateien & Pfade

| Datei | Pfad | Beschreibung |
|---|---|---|
| Update-Script | `/usr/local/bin/ipv64-update.sh` | Hauptscript |
| Logdatei | `/var/log/ipv64-update.log` | Laufende Logs |
| systemd Service | `/etc/systemd/system/ipv64-update.service` | Service-Definition (oneshot) |
| systemd Timer | `/etc/systemd/system/ipv64-update.timer` | Alle 5 Min., 30s nach Boot |
| NM Dispatcher | `/etc/NetworkManager/dispatcher.d/99-ipv64-update` | Sofort bei IPv6-Änderung |
| logrotate Config | `/etc/logrotate.d/ipv64-update` | Täglich, 14 Tage Aufbewahrung |

---

## 1. Update-Script

**`/usr/local/bin/ipv64-update.sh`**

```bash
#!/bin/bash
DOMAIN="rolandb.ipv64.de"
TOKEN="<dein-token>"           # IPv64.net Account Update Token
LOGFILE="/var/log/ipv64-update.log"
IFACE="eth0"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Auslöser: wird als Parameter übergeben, Standard = "timer"
TRIGGER="${1:-timer}"

# IPv6 lokal vom Interface lesen (kein Webcheck nötig)
# Filtert ULA-Adressen (fd.../fc...) heraus — nur öffentliche Adressen
IPV6=$(ip -6 addr show "$IFACE" scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1)

# Fehler: keine öffentliche IPv6 gefunden
if [[ -z "$IPV6" ]]; then
  echo "[$TIMESTAMP] [$TRIGGER] ERROR: Konnte keine öffentliche IPv6 auf $IFACE ermitteln" >> "$LOGFILE"
  exit 1
fi

# DNS-Eintrag direkt vom IPv64-Nameserver abfragen (kein lokales DNS-Caching)
DNS_IPV6=$(dig AAAA "$DOMAIN" +short @ns1.ipv64.net 2>/dev/null | head -1)

# Vergleich: lokale IP == DNS-Eintrag?
if [[ "$IPV6" == "$DNS_IPV6" ]]; then
  echo "[$TIMESTAMP] [$TRIGGER] INFO: Keine Änderung - DNS stimmt überein ($IPV6)" >> "$LOGFILE"
  exit 0
fi

# Update senden
RESPONSE=$(curl -s --max-time 10 \
  "https://ipv64.net/nic/update?hostname=${DOMAIN}&myip=${IPV6}" \
  -u "none:${TOKEN}")

# Antwort prüfen (IPv64.net antwortet mit JSON)
if echo "$RESPONSE" | grep -q '"status":"success"'; then
  echo "[$TIMESTAMP] [$TRIGGER] SUCCESS: DNS aktualisiert $DNS_IPV6 → $IPV6" >> "$LOGFILE"
else
  echo "[$TIMESTAMP] [$TRIGGER] ERROR: Update fehlgeschlagen. Response: $RESPONSE" >> "$LOGFILE"
  exit 1
fi
```

```bash
sudo nano /usr/local/bin/ipv64-update.sh
sudo chmod +x /usr/local/bin/ipv64-update.sh
sudo apt install dnsutils    # dig installieren falls fehlt
```

---

## 2. systemd-Timer (Fallback alle 5 Minuten)

**`/etc/systemd/system/ipv64-update.service`**
```ini
[Unit]
Description=IPv64 DynDNS Update
After=network-online.target
Requires=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipv64-update.sh
```

**`/etc/systemd/system/ipv64-update.timer`**
```ini
[Unit]
Description=IPv64 DynDNS Update Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ipv64-update.timer
```

> `Persistent=true` stellt sicher dass ein verpasster Lauf (Pi war aus) beim nächsten Start nachgeholt wird.
> `Type=oneshot` + "Deactivated successfully" im Journal ist normales Verhalten — kein Fehler.

---

## 3. NetworkManager Dispatcher (Sofortauslösung bei IPv6-Änderung)

Wird automatisch ausgeführt sobald NetworkManager eine Netzwerkänderung registriert.
Übergibt den Event-Namen ans Script → erscheint im Log als `[nm-dhcp6-change]` etc.

**`/etc/NetworkManager/dispatcher.d/99-ipv64-update`**
```bash
#!/bin/bash
INTERFACE="$1"
EVENT="$2"

if [[ "$EVENT" == "up" || "$EVENT" == "dhcp6-change" || "$EVENT" == "connectivity-change" ]]; then
  /usr/local/bin/ipv64-update.sh "nm-$EVENT"
fi
```

```bash
sudo chmod +x /etc/NetworkManager/dispatcher.d/99-ipv64-update
```

Kein Neustart von NetworkManager nötig — Scripts werden automatisch geladen.

---

## 4. logrotate

**`/etc/logrotate.d/ipv64-update`**
```conf
/var/log/ipv64-update.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
    dateext
}
```

Läuft täglich automatisch via systemd. Aufbewahrung: 14 Tage, komprimiert ab Tag 2.
Rotierten Logs: `ipv64-update.log-20260424.gz` usw.

```bash
# Logrotate testen (Dry-Run)
sudo logrotate --debug /etc/logrotate.d/ipv64-update

# Rotation manuell erzwingen
sudo logrotate --force /etc/logrotate.d/ipv64-update
```

---

## Troubleshooting

### Logs prüfen

```bash
# Live-Log verfolgen
tail -f /var/log/ipv64-update.log

# Nur Fehler anzeigen
grep ERROR /var/log/ipv64-update.log

# systemd Journal (letzte 20 Einträge)
journalctl -u ipv64-update.service -n 20

# systemd Journal live
journalctl -u ipv64-update.service -f
```

### Beispiel-Logeinträge

```
[2026-04-24 01:00:32] [timer] INFO: Keine Änderung - DNS stimmt überein (2003:eb:5726:b500:...)
[2026-04-24 01:14:17] [nm-dhcp6-change] SUCCESS: DNS aktualisiert 2003:eb:5726:... → 2003:eb:9999:...
[2026-04-24 01:15:00] [timer] INFO: Keine Änderung - DNS stimmt überein (2003:eb:9999:...)
```

### Diagnose-Befehle

```bash
# Lokale IPv6 anzeigen
ip -6 addr show eth0 scope global

# Welche IP würde das Script verwenden?
ip -6 addr show eth0 scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1

# DNS-Eintrag direkt vom IPv64-Nameserver abfragen
dig AAAA rolandb.ipv64.de +short @ns1.ipv64.net

# Timer-Status und nächster Lauf
systemctl list-timers ipv64-update.timer

# Script manuell ausführen
sudo /usr/local/bin/ipv64-update.sh manual

# Dispatcher testen
sudo nmcli networking off && sleep 2 && sudo nmcli networking on
```

### Fehler & Lösungen

| Symptom | Ursache | Fix |
|---|---|---|
| `ERROR: Konnte keine öffentliche IPv6 ermitteln` | Kein IPv6 / falsches Interface | `ip -6 addr show eth0` prüfen |
| `ERROR: Update fehlgeschlagen` | Token falsch / IPv64.net down | Token prüfen, `curl ipv64.net` testen |
| Timer läuft nicht nach Reboot | Timer nicht enabled | `sudo systemctl enable ipv64-update.timer` |
| Script nicht gefunden | Fehlende Rechte | `sudo chmod +x /usr/local/bin/ipv64-update.sh` |
| `dig` nicht gefunden | Paket fehlt | `sudo apt install dnsutils` |
| getcwd error beim Ausführen | Aktuelles Verzeichnis gelöscht | `cd ~` dann nochmal ausführen |
| Dispatcher feuert nicht | Script nicht vorhanden | `ls /etc/NetworkManager/dispatcher.d/` prüfen |

### IPv6-Adressen erklärt

Der Raspberry Pi hat zwei globale IPv6-Adressen:

| Adresse | Typ | Verwendet für |
|---|---|---|
| `2003:eb:...` | Öffentlich (Provider) | **→ Das ist die DynDNS-Adresse** |
| `fdde:...` | ULA (privat, nicht routbar) | Internes Netz (z.B. Thread/Home Assistant) |

Das Script filtert ULA-Adressen automatisch heraus (`grep -v '^f[cd]'`).

---

## IPv64.net Ressourcen

- Dashboard: https://ipv64.net
- API Dokumentation: https://ipv64.net/dyndns_updater_api
- DynDNS Helper: https://ipv64.net/dyndns_helper
