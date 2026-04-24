#!/bin/bash
# ============================================================
# IPv64 DynDNS Update – Install Script
# ============================================================
# Usage: sudo bash install.sh
# ============================================================

set -e

INTERVAL="5min"
LOG_RETAIN="14"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ "$EUID" -ne 0 ]] && error "Bitte als root ausführen: sudo bash $0"

echo ""
echo "============================================"
echo "  IPv64 DynDNS Update – Installer"
echo "============================================"
echo ""

read -rp "  Domain (z.B. meinhost.ipv64.de): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Domain darf nicht leer sein."

read -rsp "  IPv64 Update Token: " TOKEN
echo ""
[[ -z "$TOKEN" ]] && error "Token darf nicht leer sein."

info "Verfügbare Interfaces:"
ip -6 addr show scope global | grep -oP '(?<=\d: )\w+' | sort -u | sed 's/^/    /' || true
read -rp "  Interface (z.B. eth0): " IFACE
[[ -z "$IFACE" ]] && error "Interface darf nicht leer sein."

echo ""
info "Konfiguration:"
info "  Domain:        $DOMAIN"
info "  Interface:     $IFACE"
info "  Interval:      $INTERVAL"
info "  Log-Retention: ${LOG_RETAIN} Tage"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── Abhängigkeiten ───────────────────────────────────────────
info "Prüfe Abhängigkeiten..."
apt-get install -y -q dnsutils curl > /dev/null 2>&1
log "dnsutils + curl ok"

# ── Update-Script ────────────────────────────────────────────
info "Schreibe Update-Script..."
cat > /usr/local/bin/ipv64-update.sh << SCRIPT
#!/bin/bash
DOMAIN="${DOMAIN}"
TOKEN="${TOKEN}"
LOGFILE="/var/log/ipv64-update.log"
IFACE="${IFACE}"
TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')
TRIGGER="\${1:-timer}"

IPV6=\$(ip -6 addr show "\$IFACE" scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1)

if [[ -z "\$IPV6" ]]; then
  echo "[\$TIMESTAMP] [\$TRIGGER] ERROR: Konnte keine öffentliche IPv6 auf \$IFACE ermitteln" >> "\$LOGFILE"
  exit 1
fi

DNS_IPV6=\$(dig AAAA "\$DOMAIN" +short @ns1.ipv64.net 2>/dev/null | head -1)

if [[ "\$IPV6" == "\$DNS_IPV6" ]]; then
  echo "[\$TIMESTAMP] [\$TRIGGER] INFO: Keine Änderung - DNS stimmt überein (\$IPV6)" >> "\$LOGFILE"
  exit 0
fi

RESPONSE=\$(curl -s --max-time 10 \
  "https://ipv64.net/nic/update?hostname=\${DOMAIN}&myip=\${IPV6}" \
  -u "none:\${TOKEN}")

if echo "\$RESPONSE" | grep -q '"status":"success"'; then
  echo "[\$TIMESTAMP] [\$TRIGGER] SUCCESS: DNS aktualisiert \$DNS_IPV6 → \$IPV6" >> "\$LOGFILE"
else
  echo "[\$TIMESTAMP] [\$TRIGGER] ERROR: Update fehlgeschlagen. Response: \$RESPONSE" >> "\$LOGFILE"
  exit 1
fi
SCRIPT
chmod 700 /usr/local/bin/ipv64-update.sh
log "Update-Script erstellt: /usr/local/bin/ipv64-update.sh"

# ── systemd Service ──────────────────────────────────────────
info "Schreibe systemd Service..."
cat > /etc/systemd/system/ipv64-update.service << SERVICE
[Unit]
Description=IPv64 DynDNS Update
After=network-online.target
Requires=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipv64-update.sh
SERVICE
log "systemd Service erstellt"

# ── systemd Timer ────────────────────────────────────────────
info "Schreibe systemd Timer..."
cat > /etc/systemd/system/ipv64-update.timer << TIMER
[Unit]
Description=IPv64 DynDNS Update Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
TIMER
log "systemd Timer erstellt"

systemctl daemon-reload
systemctl enable --now ipv64-update.timer
log "Timer aktiviert und gestartet"

# ── NetworkManager Dispatcher ────────────────────────────────
if systemctl is-active --quiet NetworkManager; then
  info "NetworkManager erkannt – schreibe Dispatcher..."
  cat > /etc/NetworkManager/dispatcher.d/99-ipv64-update << DISPATCHER
#!/bin/bash
INTERFACE="\$1"
EVENT="\$2"

if [[ "\$EVENT" == "up" || "\$EVENT" == "dhcp6-change" || "\$EVENT" == "connectivity-change" ]]; then
  /usr/local/bin/ipv64-update.sh "nm-\$EVENT"
fi
DISPATCHER
  chmod +x /etc/NetworkManager/dispatcher.d/99-ipv64-update
  log "NetworkManager Dispatcher erstellt"
else
  warn "NetworkManager nicht aktiv – Dispatcher übersprungen"
fi

# ── logrotate ────────────────────────────────────────────────
info "Schreibe logrotate Konfiguration..."
cat > /etc/logrotate.d/ipv64-update << LOGROTATE
/var/log/ipv64-update.log {
    daily
    rotate ${LOG_RETAIN}
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
    dateext
}
LOGROTATE
log "logrotate konfiguriert (täglich, ${LOG_RETAIN} Tage)"

# ── Erster Test-Lauf ─────────────────────────────────────────
echo ""
info "Führe ersten Test-Lauf durch..."
/usr/local/bin/ipv64-update.sh "install"
echo ""
log "Ergebnis:"
tail -1 /var/log/ipv64-update.log
echo ""

echo "============================================"
echo -e "  ${GREEN}Installation abgeschlossen!${NC}"
echo "============================================"
echo ""
echo "  Nützliche Befehle:"
echo "    Log:       tail -f /var/log/ipv64-update.log"
echo "    Timer:     systemctl list-timers ipv64-update.timer"
echo "    Manuell:   sudo /usr/local/bin/ipv64-update.sh manual"
echo "    Update:    sudo bash ${SCRIPT_DIR}/update.sh"
echo "    Entfernen: sudo bash ${SCRIPT_DIR}/uninstall.sh"
echo ""
