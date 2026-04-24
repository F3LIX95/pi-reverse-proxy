#!/bin/bash
# ============================================================
# Nginx Reverse Proxy – Update Script
# Changes backend URL and/or port for an existing proxy.
# ============================================================
# Usage: sudo bash update.sh [proxy-name]
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_STORE="/etc/nginx/sites-available"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ "$EUID" -ne 0 ]] && error "Bitte als root ausführen: sudo bash $0 [proxy-name]"

echo ""
echo "============================================"
echo "  Nginx Reverse Proxy – Update"
echo "============================================"
echo ""

# ── Proxy-Name bestimmen ─────────────────────────────────────
PROXY_NAME="$1"
if [[ -z "$PROXY_NAME" ]]; then
  AVAILABLE=$(ls "${SCRIPT_DIR}"/.*.conf 2>/dev/null | sed 's|.*\.||;s|\.conf$||' || true)
  if [[ -z "$AVAILABLE" ]]; then
    error "Keine installierten Proxys gefunden. Bitte zuerst install.sh ausführen."
  fi
  info "Installierte Proxys:"
  echo "$AVAILABLE" | sed 's/^/    /'
  echo ""
  read -rp "  Proxy-Name: " PROXY_NAME
  [[ -z "$PROXY_NAME" ]] && error "Name darf nicht leer sein."
fi

META_FILE="${SCRIPT_DIR}/.${PROXY_NAME}.conf"
CONF_FILE="${CONFIG_STORE}/${PROXY_NAME}"

[[ ! -f "$META_FILE" ]] && error "Konfiguration für '${PROXY_NAME}' nicht gefunden: $META_FILE"
[[ ! -f "$CONF_FILE" ]] && error "nginx-Konfiguration nicht gefunden: $CONF_FILE"

# shellcheck source=/dev/null
source "$META_FILE"

# ── Neue Werte abfragen ──────────────────────────────────────
info "Aktuelle Werte (Enter = unverändert):"
echo ""

read -rp "  Backend-URL [$BACKEND_URL]: " NEW_URL
NEW_URL="${NEW_URL:-$BACKEND_URL}"
NEW_URL="${NEW_URL%/}"

read -rp "  Port [$PORT]: " NEW_PORT
NEW_PORT="${NEW_PORT:-$PORT}"
[[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] && error "Port muss eine Zahl sein."

echo ""
info "Neue Konfiguration:"
info "  Backend: ${NEW_URL}:${NEW_PORT}"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── nginx-Konfiguration neu schreiben ────────────────────────
info "Schreibe nginx-Konfiguration..."
cat > "$CONF_FILE" << NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen [::]:${NEW_PORT} ipv6only=off;

    server_name _;

    location / {
        proxy_pass         ${NEW_URL}:${NEW_PORT};

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;

        proxy_set_header   Host              $(echo "$NEW_URL" | sed 's|https\?://||'):${NEW_PORT};
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }
}
NGINX
log "nginx-Konfiguration aktualisiert"

# ── Meta-Datei aktualisieren ─────────────────────────────────
cat > "$META_FILE" << META
PROXY_NAME="${PROXY_NAME}"
BACKEND_URL="${NEW_URL}"
PORT="${NEW_PORT}"
META
log "Proxy-Konfiguration gespeichert"

# ── nginx testen und neu laden ───────────────────────────────
info "Teste nginx-Konfiguration..."
nginx -t
log "Konfiguration gültig"

systemctl reload nginx
log "nginx neu geladen"

echo ""
log "Update abgeschlossen: ${PROXY_NAME} → ${NEW_URL}:${NEW_PORT}"
echo ""
