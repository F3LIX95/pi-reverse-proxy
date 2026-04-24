#!/bin/bash
# ============================================================
# Nginx Reverse Proxy – Uninstall Script
# Removes a specific proxy config or all proxies.
# ============================================================
# Usage: sudo bash uninstall.sh [proxy-name]
#        Omit proxy-name to be prompted or remove all.
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

[[ "$EUID" -ne 0 ]] && error "Bitte als root ausführen: sudo bash $0 [proxy-name]"

echo ""
echo "============================================"
echo "  Nginx Reverse Proxy – Deinstallation"
echo "============================================"
echo ""

# ── Proxy-Name bestimmen ─────────────────────────────────────
PROXY_NAME="$1"
if [[ -z "$PROXY_NAME" ]]; then
  AVAILABLE=$(ls "${SCRIPT_DIR}"/.*.conf 2>/dev/null | xargs -I{} bash -c 'source "{}"; echo "$PROXY_NAME"' 2>/dev/null || true)
  if [[ -z "$AVAILABLE" ]]; then
    error "Keine installierten Proxys gefunden."
  fi
  info "Installierte Proxys:"
  echo "$AVAILABLE" | sed 's/^/    /'
  echo ""
  read -rp "  Proxy-Name (oder 'alle' für alle): " PROXY_NAME
  [[ -z "$PROXY_NAME" ]] && error "Name darf nicht leer sein."
fi

remove_proxy() {
  local name="$1"
  local conf="${CONFIG_STORE}/${name}"
  local link="${ENABLED_DIR}/${name}"
  local meta="${SCRIPT_DIR}/.${name}.conf"

  info "Entferne Proxy: $name"

  if [[ -L "$link" ]]; then
    rm -f "$link"
    log "  Site deaktiviert: $link"
  fi
  if [[ -f "$conf" ]]; then
    rm -f "$conf"
    log "  Konfiguration entfernt: $conf"
  fi
  if [[ -f "$meta" ]]; then
    rm -f "$meta"
    log "  Meta-Datei entfernt: $meta"
  fi
}

if [[ "$PROXY_NAME" == "alle" ]]; then
  warn "Alle Proxys werden entfernt."
  read -rp "  Wirklich fortfahren? [j/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
  echo ""
  for meta in "${SCRIPT_DIR}"/.*.conf; do
    [[ -f "$meta" ]] || continue
    # shellcheck source=/dev/null
    source "$meta"
    remove_proxy "$PROXY_NAME"
  done
else
  warn "Proxy '${PROXY_NAME}' wird entfernt."
  read -rp "  Fortfahren? [j/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
  echo ""
  remove_proxy "$PROXY_NAME"
fi

# ── nginx testen und neu laden ───────────────────────────────
info "Teste nginx-Konfiguration..."
nginx -t
log "Konfiguration gültig"

systemctl reload nginx
log "nginx neu geladen"

echo ""
echo "============================================"
echo -e "  ${GREEN}Deinstallation abgeschlossen.${NC}"
echo "============================================"
echo ""
