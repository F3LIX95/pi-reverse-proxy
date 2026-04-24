#!/bin/bash
# ============================================================
# Nginx Reverse Proxy – Install Script
# - Listens on 443 (HTTPS) with a Let's Encrypt certificate
# - Port 80 is kept open only for ACME renewal challenges
#   and redirects all other traffic to HTTPS
# - Proxies to an IPv4-only backend on the local network
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

read -rp "  FQDN (z.B. myhost.ipv64.de): " FQDN
[[ -z "$FQDN" ]] && error "FQDN darf nicht leer sein."

read -rp "  E-Mail für Let's Encrypt (Ablaufbenachrichtigungen): " EMAIL
[[ -z "$EMAIL" ]] && error "E-Mail darf nicht leer sein."

read -rp "  Backend-URL (z.B. http://loxone.fritz.box): " BACKEND_URL
[[ -z "$BACKEND_URL" ]] && error "Backend-URL darf nicht leer sein."
BACKEND_URL="${BACKEND_URL%/}"

read -rp "  Backend-Port (z.B. 1907): " BACKEND_PORT
[[ -z "$BACKEND_PORT" ]] && error "Backend-Port darf nicht leer sein."
[[ ! "$BACKEND_PORT" =~ ^[0-9]+$ ]] && error "Port muss eine Zahl sein."

BACKEND_HOST=$(echo "$BACKEND_URL" | sed 's|https\?://||;s|/.*||')
CONF_FILE="${CONFIG_STORE}/${PROXY_NAME}"
LINK_FILE="${ENABLED_DIR}/${PROXY_NAME}"

echo ""
info "Konfiguration:"
info "  Name:         $PROXY_NAME"
info "  FQDN:         $FQDN"
info "  Öffentlich:   https://${FQDN}  (Port 443)"
info "  Backend:      ${BACKEND_URL}:${BACKEND_PORT}"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── Pakete installieren ──────────────────────────────────────
info "Installiere nginx + certbot..."
apt-get install -y -q nginx certbot python3-certbot-nginx > /dev/null 2>&1
log "nginx + certbot ok"

# ── net.ipv6.bindv6only=0 (dual-stack single socket) ─────────
if ! grep -q 'net.ipv6.bindv6only' /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv6.bindv6only = 0" >> /etc/sysctl.conf
  sysctl -p > /dev/null 2>&1
  log "net.ipv6.bindv6only=0 gesetzt"
fi

# ── Default-Site deaktivieren (würde Port 80/443 blockieren) ─
if [[ -L "${ENABLED_DIR}/default" ]]; then
  rm -f "${ENABLED_DIR}/default"
  log "Default-Site deaktiviert"
fi

# ── Temporäre HTTP-Konfiguration für ACME-Challenge ──────────
info "Schreibe temporäre HTTP-Konfiguration für ACME-Challenge..."
cat > "$CONF_FILE" << NGINX
server {
    listen [::]:80 ipv6only=off;
    server_name ${FQDN};
    root /var/www/html;
}
NGINX

if [[ ! -L "$LINK_FILE" ]]; then
  ln -s "$CONF_FILE" "$LINK_FILE"
fi

systemctl enable nginx > /dev/null 2>&1
nginx -t
systemctl reload-or-restart nginx
log "nginx neu geladen (HTTP)"

# ── Let's Encrypt Zertifikat holen ───────────────────────────
info "Hole Let's Encrypt Zertifikat für ${FQDN}..."
certbot certonly \
  --nginx \
  -d "$FQDN" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive
log "Zertifikat erhalten: /etc/letsencrypt/live/${FQDN}/"

# ── Deploy-Hook: nginx nach Erneuerung neu laden ──────────────
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
log "Renewal deploy-hook eingerichtet"

# ── Lokalen DNS-Resolver ermitteln ───────────────────────────
RESOLVER=$(grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print $2}')
[[ -z "$RESOLVER" ]] && RESOLVER="127.0.0.53"
log "DNS-Resolver: $RESOLVER"

# ── Finale nginx-Konfiguration (HTTPS + Proxy) ────────────────
info "Schreibe finale nginx-Konfiguration..."
cat > "$CONF_FILE" << NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP → HTTPS redirect; ACME challenges pass through
server {
    listen [::]:80 ipv6only=off;
    server_name ${FQDN};

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
    server_name ${FQDN};

    ssl_certificate     /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Defer backend DNS resolution to request time so local hostnames
    # (e.g. loxone.fritz.box) don't cause nginx -t to fail at startup.
    resolver ${RESOLVER} valid=30s ipv6=off;

    location / {
        set \$upstream ${BACKEND_URL}:${BACKEND_PORT};
        proxy_pass \$upstream;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$connection_upgrade;

        proxy_set_header   Host              ${BACKEND_HOST}:${BACKEND_PORT};
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
    }
}
NGINX
log "nginx-Konfiguration geschrieben: $CONF_FILE"

# ── nginx testen und neu laden ───────────────────────────────
info "Teste nginx-Konfiguration..."
nginx -t
log "Konfiguration gültig"

systemctl reload nginx
log "nginx neu geladen (HTTPS aktiv)"

# ── Ports prüfen ─────────────────────────────────────────────
sleep 1
ss -tlnp | grep -q ':80'  && log "Port 80  ist offen" || warn "Port 80  scheint nicht zu lauschen"
ss -tlnp | grep -q ':443' && log "Port 443 ist offen" || warn "Port 443 scheint nicht zu lauschen"

# ── Konfiguration für Update/Uninstall speichern ─────────────
cat > "${SCRIPT_DIR}/.${PROXY_NAME}.conf" << META
PROXY_NAME="${PROXY_NAME}"
FQDN="${FQDN}"
EMAIL="${EMAIL}"
BACKEND_URL="${BACKEND_URL}"
BACKEND_PORT="${BACKEND_PORT}"
META
chmod 600 "${SCRIPT_DIR}/.${PROXY_NAME}.conf"
log "Meta-Konfiguration gespeichert"

echo ""
echo "============================================"
echo -e "  ${GREEN}Installation abgeschlossen!${NC}"
echo "============================================"
echo ""
echo "  Fritzbox – benötigte IPv6-Portfreigaben:"
echo "    TCP 80  → Pi-IPv6  (Let's Encrypt Renewal)"
echo "    TCP 443 → Pi-IPv6  (HTTPS Proxy)"
echo ""
echo "  Test:"
echo "    curl -v https://${FQDN}"
echo ""
echo "  Nützliche Befehle:"
echo "    nginx-Log:    sudo tail -f /var/log/nginx/error.log"
echo "    Zertifikat:   sudo certbot certificates"
echo "    Renewal-Test: sudo certbot renew --dry-run"
echo "    Update:       sudo bash ${SCRIPT_DIR}/update.sh ${PROXY_NAME}"
echo "    Entfernen:    sudo bash ${SCRIPT_DIR}/uninstall.sh ${PROXY_NAME}"
echo ""
