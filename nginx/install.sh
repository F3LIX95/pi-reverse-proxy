#!/bin/bash
# ============================================================
# Nginx Reverse Proxy – Install Script
# Exposes an IPv4-only backend via IPv6 (and IPv4)
# ============================================================
# Usage: sudo bash install.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_STORE="/etc/nginx/sites-available"
ENABLED_DIR="/etc/nginx/sites-enabled"

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
echo "  Nginx Reverse Proxy – Installer"
echo "============================================"
echo ""

read -rp "  Name für diesen Proxy (z.B. loxone1): " PROXY_NAME
[[ -z "$PROXY_NAME" ]] && error "Name darf nicht leer sein."

read -rp "  Backend-URL (z.B. http://loxone.fritz.box): " BACKEND_URL
[[ -z "$BACKEND_URL" ]] && error "Backend-URL darf nicht leer sein."
# Strip trailing slash
BACKEND_URL="${BACKEND_URL%/}"

read -rp "  Port (z.B. 1907): " PORT
[[ -z "$PORT" ]] && error "Port darf nicht leer sein."
[[ ! "$PORT" =~ ^[0-9]+$ ]] && error "Port muss eine Zahl sein."

CONF_FILE="${CONFIG_STORE}/${PROXY_NAME}"
LINK_FILE="${ENABLED_DIR}/${PROXY_NAME}"

echo ""
info "Konfiguration:"
info "  Name:    $PROXY_NAME"
info "  Backend: ${BACKEND_URL}:${PORT}"
info "  Port:    $PORT (IPv4 + IPv6)"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── nginx installieren ───────────────────────────────────────
info "Installiere nginx..."
apt-get install -y -q nginx > /dev/null 2>&1
log "nginx ok"

# ── net.ipv6.bindv6only=0 (dual-stack single socket) ─────────
if ! grep -q 'net.ipv6.bindv6only' /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv6.bindv6only = 0" >> /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
  log "net.ipv6.bindv6only=0 gesetzt"
fi

# ── nginx-Konfiguration schreiben ────────────────────────────
info "Schreibe nginx-Konfiguration..."
cat > "$CONF_FILE" << NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen [::]:${PORT} ipv6only=off;

    server_name _;

    location / {
        proxy_pass         ${BACKEND_URL}:${PORT};

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;

        proxy_set_header   Host              $(echo "$BACKEND_URL" | sed 's|https\?://||'):${PORT};
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }
}
NGINX
log "Konfiguration geschrieben: $CONF_FILE"

# ── Site aktivieren ──────────────────────────────────────────
if [[ ! -L "$LINK_FILE" ]]; then
  ln -s "$CONF_FILE" "$LINK_FILE"
  log "Site aktiviert: $LINK_FILE"
fi

# ── Konfiguration testen & nginx neu laden ───────────────────
info "Teste nginx-Konfiguration..."
nginx -t
log "Konfiguration gültig"

systemctl enable nginx > /dev/null 2>&1
systemctl reload-or-restart nginx
log "nginx neu geladen"

# ── Port prüfen ──────────────────────────────────────────────
sleep 1
if ss -tlnp | grep -q ":${PORT}"; then
  log "Port ${PORT} ist offen"
else
  warn "Port ${PORT} scheint nicht zu lauschen – Log prüfen: sudo journalctl -u nginx -n 30"
fi

# ── Konfiguration für spätere Updates speichern ──────────────
cat > "${SCRIPT_DIR}/.${PROXY_NAME}.conf" << META
PROXY_NAME="${PROXY_NAME}"
BACKEND_URL="${BACKEND_URL}"
PORT="${PORT}"
META
chmod 600 "${SCRIPT_DIR}/.${PROXY_NAME}.conf"
log "Proxy-Konfiguration gespeichert: ${SCRIPT_DIR}/.${PROXY_NAME}.conf"

echo ""
echo "============================================"
echo -e "  ${GREEN}Installation abgeschlossen!${NC}"
echo "============================================"
echo ""
echo "  Nächste Schritte:"
echo "    1. Fritzbox: IPv6-Portfreigabe TCP ${PORT} → diese Pi-IP"
echo "    2. Test lokal:   curl -v http://localhost:${PORT}"
echo ""
echo "  Nützliche Befehle:"
echo "    nginx-Log:   sudo tail -f /var/log/nginx/error.log"
echo "    Port prüfen: ss -tlnp | grep ${PORT}"
echo "    Update:      sudo bash ${SCRIPT_DIR}/update.sh ${PROXY_NAME}"
echo "    Entfernen:   sudo bash ${SCRIPT_DIR}/uninstall.sh ${PROXY_NAME}"
echo ""
