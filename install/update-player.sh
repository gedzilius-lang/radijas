#!/usr/bin/env bash
###############################################################################
# update-player.sh
# Deploys the web player from the website/ directory
#
# Usage (on VPS as root):
#   curl -fsSL https://raw.githubusercontent.com/gedzilius-lang/radijas/claude/setup-radio-agent-instructions-ghStP/install/update-player.sh | bash
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK:${NC} $1"; }
step() { echo -e "\n${CYAN}>>> $1${NC}"; }

DOMAIN="${DOMAIN:-radio.peoplewelike.club}"
WEBROOT="/var/www/${DOMAIN}"
BRANCH="claude/setup-radio-agent-instructions-ghStP"
RAW_BASE="https://raw.githubusercontent.com/gedzilius-lang/radijas/${BRANCH}/website"

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root${NC}"; exit 1; fi

step "Downloading website files from repo"
mkdir -p "$WEBROOT"

curl -fsSL "${RAW_BASE}/index.html" -o "${WEBROOT}/index.html"
ok "index.html"

curl -fsSL "${RAW_BASE}/404.html" -o "${WEBROOT}/404.html"
ok "404.html"

curl -fsSL "${RAW_BASE}/50x.html" -o "${WEBROOT}/50x.html"
ok "50x.html"

curl -fsSL "${RAW_BASE}/poster.svg" -o "${WEBROOT}/poster.svg"
ok "poster.svg"

# Generate poster.jpg from SVG
ffmpeg -y -i "${WEBROOT}/poster.svg" -vf "scale=1920:1080" "${WEBROOT}/poster.jpg" 2>/dev/null || true
ok "poster.jpg generated"

chown -R www-data:www-data "$WEBROOT"
chmod -R 755 "$WEBROOT"

step "Done"
echo -e "${GREEN}Player deployed to ${WEBROOT}${NC}"
echo -e "Test: https://${DOMAIN}/"
