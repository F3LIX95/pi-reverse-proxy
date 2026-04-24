#!/bin/bash
# ============================================================
# IPv64 DynDNS Update – Uninstall Script
# Removes all installed files and systemd units.
# ============================================================
# Usage: sudo bash uninstall.sh
# ============================================================

set -e

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
echo "  IPv64 DynDNS Update – Deinstallation"
echo "============================================"
echo ""
warn "Folgende Dateien werden entfernt:"
echo "    /usr/local/bin/ipv64-update.sh"
echo "    /etc/systemd/system/ipv64-update.service"
echo "    /etc/systemd/system/ipv64-update.timer"
echo "    /etc/NetworkManager/dispatcher.d/99-ipv64-update"
echo "    /etc/logrotate.d/ipv64-update"
echo ""
warn "Die Logdatei /var/log/ipv64-update.log wird NICHT gelöscht."
echo ""
read -rp "  Fortfahren? [j/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 0; }
echo ""

# ── systemd Timer und Service stoppen/deaktivieren ───────────
if systemctl is-active --quiet ipv64-update.timer 2>/dev/null; then
  systemctl disable --now ipv64-update.timer
  log "Timer deaktiviert"
fi

if systemctl is-enabled --quiet ipv64-update.timer 2>/dev/null; then
  systemctl disable ipv64-update.timer
fi

# ── Dateien entfernen ────────────────────────────────────────
remove() {
  if [[ -e "$1" ]]; then
    rm -f "$1"
    log "Entfernt: $1"
  else
    info "Nicht vorhanden (übersprungen): $1"
  fi
}

remove /usr/local/bin/ipv64-update.sh
remove /etc/systemd/system/ipv64-update.service
remove /etc/systemd/system/ipv64-update.timer
remove /etc/NetworkManager/dispatcher.d/99-ipv64-update
remove /etc/logrotate.d/ipv64-update

systemctl daemon-reload
log "systemd neu geladen"

echo ""
echo "============================================"
echo -e "  ${GREEN}Deinstallation abgeschlossen.${NC}"
echo "============================================"
echo ""
info "Log bleibt erhalten: /var/log/ipv64-update.log"
echo ""
