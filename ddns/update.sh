#!/bin/bash
# ============================================================
# IPv64 DynDNS Update – Update Script
# Rewrites /usr/local/bin/ipv64-update.sh with new config
# and the latest script logic.
# ============================================================
# Usage: sudo bash update.sh
# ============================================================

set -e

SCRIPT="/usr/local/bin/ipv64-update.sh"

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
[[ ! -f "$SCRIPT" ]] && error "ipv64-update.sh nicht gefunden. Bitte zuerst install.sh ausführen."

# ── Aktuelle Werte auslesen ──────────────────────────────────
CUR_DOMAIN=$(grep '^DOMAIN='  "$SCRIPT" | cut -d'"' -f2)
CUR_TOKEN=$(grep '^TOKEN='    "$SCRIPT" | cut -d'"' -f2)
CUR_API_KEY=$(grep '^API_KEY=' "$SCRIPT" | cut -d'"' -f2)
CUR_IFACE=$(grep '^IFACE='    "$SCRIPT" | cut -d'"' -f2)

echo ""
echo "============================================"
echo "  IPv64 DynDNS Update – Konfiguration ändern"
echo "============================================"
echo ""
info "Aktuelle Werte (Enter = unverändert):"
echo ""

read -rp "  Domain [$CUR_DOMAIN]: " NEW_DOMAIN
NEW_DOMAIN="${NEW_DOMAIN:-$CUR_DOMAIN}"

read -rp "  DynDNS Update Token (leer = unverändert): " NEW_TOKEN
NEW_TOKEN="${NEW_TOKEN:-$CUR_TOKEN}"

read -rp "  Account API Key (leer = unverändert): " NEW_API_KEY
NEW_API_KEY="${NEW_API_KEY:-$CUR_API_KEY}"

read -rp "  Interface [$CUR_IFACE]: " NEW_IFACE
NEW_IFACE="${NEW_IFACE:-$CUR_IFACE}"

echo ""
info "Neue Konfiguration:"
info "  Domain:    $NEW_DOMAIN"
info "  Interface: $NEW_IFACE"
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── Script komplett neu schreiben (inkl. aktueller Logik) ────
info "Schreibe Update-Script..."
cat > "$SCRIPT" << SCRIPT
#!/bin/bash
DOMAIN="${NEW_DOMAIN}"
TOKEN="${NEW_TOKEN}"
API_KEY="${NEW_API_KEY}"
LOGFILE="/var/log/ipv64-update.log"
IFACE="${NEW_IFACE}"
TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')
TRIGGER="\${1:-timer}"

# Current public IPv6 on this interface
IPV6=\$(ip -6 addr show "\$IFACE" scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1)

if [[ -z "\$IPV6" ]]; then
  echo "[\$TIMESTAMP] [\$TRIGGER] ERROR: Konnte keine öffentliche IPv6 auf \$IFACE ermitteln" >> "\$LOGFILE"
  exit 1
fi

# Query the IPv64 API for the stored AAAA record – avoids CDN/proxy IPs
# that a DNS lookup would return when the CDN reverse proxy is active.
# The API key in .subdomains is the full domain; praefix="" for apex records.
API_RESPONSE=\$(curl -s --max-time 10 \
  "https://ipv64.net/api.php?get_domains" \
  -H "Authorization: Bearer \${API_KEY}")

# When CDN is active IPv64 marks the real Pi IP as deactivated=1 and adds
# a second record with the CDN IP as deactivated=0. Use deactivated=1 first.
API_IPV6=\$(echo "\$API_RESPONSE" \
  | jq -r --arg domain "\$DOMAIN" \
    '.subdomains[\$domain].records[]
     | select(.praefix == "" and .type == "AAAA" and .deactivated == 1)
     | .content' 2>/dev/null | head -1)

# Fallback: CDN is off, only one active AAAA record exists
if [[ -z "\$API_IPV6" ]]; then
  API_IPV6=\$(echo "\$API_RESPONSE" \
    | jq -r --arg domain "\$DOMAIN" \
      '.subdomains[\$domain].records[]
       | select(.praefix == "" and .type == "AAAA" and .deactivated == 0)
       | .content' 2>/dev/null | head -1)
fi

if [[ -z "\$API_IPV6" ]]; then
  echo "[\$TIMESTAMP] [\$TRIGGER] ERROR: API-Abfrage fehlgeschlagen oder kein AAAA-Eintrag gefunden" >> "\$LOGFILE"
  exit 1
fi

if [[ "\$IPV6" == "\$API_IPV6" ]]; then
  echo "[\$TIMESTAMP] [\$TRIGGER] INFO: Keine Änderung (\$IPV6)" >> "\$LOGFILE"
  exit 0
fi

UPDATE_RESPONSE=\$(curl -s --max-time 10 \
  "https://ipv64.net/nic/update?hostname=\${DOMAIN}&myip=\${IPV6}" \
  -u "none:\${TOKEN}")

if echo "\$UPDATE_RESPONSE" | grep -q '"status":"success"'; then
  echo "[\$TIMESTAMP] [\$TRIGGER] SUCCESS: DNS aktualisiert \$API_IPV6 → \$IPV6" >> "\$LOGFILE"
else
  echo "[\$TIMESTAMP] [\$TRIGGER] ERROR: Update fehlgeschlagen. Response: \$UPDATE_RESPONSE" >> "\$LOGFILE"
  exit 1
fi
SCRIPT
chmod 700 "$SCRIPT"
log "Script aktualisiert: $SCRIPT"

# ── jq sicherstellen ─────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  info "Installiere jq..."
  apt-get install -y -q jq > /dev/null 2>&1
  log "jq installiert"
fi

# ── Test-Lauf ────────────────────────────────────────────────
echo ""
info "Führe Test-Lauf durch..."
"$SCRIPT" "update"
echo ""
log "Ergebnis:"
tail -1 /var/log/ipv64-update.log
echo ""

log "Update abgeschlossen."
