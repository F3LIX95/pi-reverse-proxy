#!/bin/bash
# ============================================================
# Nginx Reverse Proxy – Update Script
# Change backend URL/port or rotate the TLS certificate
# (e.g. after a domain change) without full reinstall.
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
  AVAILABLE=$(ls "${SCRIPT_DIR}"/.*.conf 2>/dev/null \
    | xargs -I{} bash -c 'source "{}"; echo "$PROXY_NAME"' 2>/dev/null || true)
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

read -rp "  FQDN [$FQDN]: " NEW_FQDN
NEW_FQDN="${NEW_FQDN:-$FQDN}"

read -rp "  Backend-URL [$BACKEND_URL]: " NEW_URL
NEW_URL="${NEW_URL:-$BACKEND_URL}"
NEW_URL="${NEW_URL%/}"

read -rp "  Backend-Port [$BACKEND_PORT]: " NEW_PORT
NEW_PORT="${NEW_PORT:-$BACKEND_PORT}"
[[ ! "$NEW_PORT" =~ ^[0-9]+$ ]] && error "Port muss eine Zahl sein."

NEW_BACKEND_HOST=$(echo "$NEW_URL" | sed 's|https\?://||;s|/.*||')

echo ""
info "Neue Konfiguration:"
info "  FQDN:    $NEW_FQDN"
info "  Backend: ${NEW_URL}:${NEW_PORT}"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── Neues Zertifikat holen wenn FQDN geändert ────────────────
CERT_PATH="/etc/letsencrypt/live/${NEW_FQDN}/fullchain.pem"
if [[ "$NEW_FQDN" != "$FQDN" ]]; then
  info "FQDN geändert – hole neues Let's Encrypt Zertifikat..."
  certbot certonly \
    --nginx \
    -d "$NEW_FQDN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive
  log "Zertifikat erhalten: /etc/letsencrypt/live/${NEW_FQDN}/"
elif [[ ! -f "$CERT_PATH" ]]; then
  warn "Zertifikat für ${NEW_FQDN} nicht gefunden. Bitte certbot manuell ausführen:"
  warn "  sudo certbot certonly --nginx -d ${NEW_FQDN}"
fi

# ── Lokalen DNS-Resolver ermitteln ───────────────────────────
RESOLVER=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')
[[ -z "$RESOLVER" ]] && RESOLVER="127.0.0.53"

# ── nginx-Konfiguration neu schreiben ────────────────────────
info "Schreibe nginx-Konfiguration..."
cat > "$CONF_FILE" << NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP → HTTPS redirect; ACME challenges pass through
server {
    listen [::]:80 ipv6only=off;
    server_name ${NEW_FQDN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS reverse proxy
server {
    listen [::]:443 ssl ipv6only=off;
    http2 on;
    server_name ${NEW_FQDN};

    ssl_certificate     /etc/letsencrypt/live/${NEW_FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${NEW_FQDN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Defer backend DNS resolution to request time so local hostnames
    # (e.g. loxone.fritz.box) don't cause nginx -t to fail at startup.
    resolver ${RESOLVER} valid=30s ipv6=off;

    location / {
        set \$upstream ${NEW_URL}:${NEW_PORT};
        proxy_pass \$upstream;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;

        proxy_set_header   Host              ${NEW_BACKEND_HOST}:${NEW_PORT};
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
FQDN="${NEW_FQDN}"
EMAIL="${EMAIL}"
BACKEND_URL="${NEW_URL}"
BACKEND_PORT="${NEW_PORT}"
META
log "Meta-Konfiguration gespeichert"

# ── nginx testen und neu laden ───────────────────────────────
info "Teste nginx-Konfiguration..."
nginx -t
log "Konfiguration gültig"

systemctl reload nginx
log "nginx neu geladen"

echo ""
log "Update abgeschlossen: ${PROXY_NAME} → https://${NEW_FQDN} → ${NEW_URL}:${NEW_PORT}"
echo ""
