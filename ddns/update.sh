#!/bin/bash
# ============================================================
# IPv64 DynDNS Update – Update Script
# Updates domain, token, and/or interface in the running setup
# without a full reinstall.
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
CUR_DOMAIN=$(grep '^DOMAIN=' "$SCRIPT" | cut -d'"' -f2)
CUR_TOKEN=$(grep '^TOKEN='  "$SCRIPT" | cut -d'"' -f2)
CUR_IFACE=$(grep '^IFACE='  "$SCRIPT" | cut -d'"' -f2)

echo ""
echo "============================================"
echo "  IPv64 DynDNS Update – Konfiguration ändern"
echo "============================================"
echo ""
info "Aktuelle Werte (Enter = unverändert):"
echo ""

read -rp "  Domain [$CUR_DOMAIN]: " NEW_DOMAIN
NEW_DOMAIN="${NEW_DOMAIN:-$CUR_DOMAIN}"

read -rsp "  Token (leer = unverändert): " NEW_TOKEN
echo ""
NEW_TOKEN="${NEW_TOKEN:-$CUR_TOKEN}"

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

# ── Werte ersetzen ───────────────────────────────────────────
sed -i "s|^DOMAIN=.*|DOMAIN=\"${NEW_DOMAIN}\"|" "$SCRIPT"
sed -i "s|^TOKEN=.*|TOKEN=\"${NEW_TOKEN}\"|"   "$SCRIPT"
sed -i "s|^IFACE=.*|IFACE=\"${NEW_IFACE}\"|"  "$SCRIPT"
log "Konfiguration aktualisiert"

# ── Test-Lauf ────────────────────────────────────────────────
echo ""
info "Führe Test-Lauf durch..."
/usr/local/bin/ipv64-update.sh "update"
echo ""
log "Ergebnis:"
tail -1 /var/log/ipv64-update.log
echo ""

log "Update abgeschlossen."
