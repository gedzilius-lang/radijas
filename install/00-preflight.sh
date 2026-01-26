#!/usr/bin/env bash
###############################################################################
# PREFLIGHT CHECK - Run this first to verify system readiness
# People We Like Radio Installation
###############################################################################
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=============================================="
echo "  People We Like Radio - Preflight Check"
echo "=============================================="
echo ""

ERRORS=0

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[FAIL]${NC} Must run as root"
   ERRORS=$((ERRORS+1))
else
   echo -e "${GREEN}[OK]${NC} Running as root"
fi

# Check Ubuntu version
if grep -q "22.04" /etc/os-release 2>/dev/null; then
   echo -e "${GREEN}[OK]${NC} Ubuntu 22.04 detected"
else
   echo -e "${YELLOW}[WARN]${NC} Expected Ubuntu 22.04, found: $(lsb_release -ds 2>/dev/null || echo 'unknown')"
fi

# Check existing nginx
if systemctl is-active --quiet nginx 2>/dev/null; then
   echo -e "${GREEN}[OK]${NC} nginx is running"
else
   echo -e "${YELLOW}[WARN]${NC} nginx not running (will be installed/configured)"
fi

# Check ports
echo ""
echo "Checking port availability..."

for port in 1935 8089; do
   if ss -tlnp | grep -q ":${port} "; then
      echo -e "${YELLOW}[WARN]${NC} Port $port already in use"
   else
      echo -e "${GREEN}[OK]${NC} Port $port is available"
   fi
done

# Check if av.peoplewelike.club exists (must not touch)
if [[ -d /var/www/av.peoplewelike.club ]]; then
   echo -e "${GREEN}[OK]${NC} Found existing av.peoplewelike.club (will NOT modify)"
fi

if [[ -f /etc/nginx/sites-enabled/av.peoplewelike.club.conf ]]; then
   echo -e "${GREEN}[OK]${NC} Found existing av.peoplewelike.club nginx config (will NOT modify)"
fi

# Check DNS resolution
echo ""
echo "Checking DNS resolution..."

for domain in radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club; do
   resolved=$(getent ahosts "$domain" 2>/dev/null | head -1 | awk '{print $1}')
   if [[ "$resolved" == "72.60.181.89" ]]; then
      echo -e "${GREEN}[OK]${NC} $domain → $resolved"
   else
      echo -e "${RED}[FAIL]${NC} $domain does not resolve to 72.60.181.89 (got: ${resolved:-none})"
      ERRORS=$((ERRORS+1))
   fi
done

# Check disk space
echo ""
AVAIL=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$AVAIL" -gt 10 ]]; then
   echo -e "${GREEN}[OK]${NC} Disk space: ${AVAIL}GB available"
else
   echo -e "${YELLOW}[WARN]${NC} Low disk space: ${AVAIL}GB available (recommend >10GB)"
fi

# Check RAM
MEM=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$MEM" -gt 2000 ]]; then
   echo -e "${GREEN}[OK]${NC} RAM: ${MEM}MB"
else
   echo -e "${YELLOW}[WARN]${NC} Low RAM: ${MEM}MB (recommend >2GB)"
fi

# Summary
echo ""
echo "=============================================="
if [[ $ERRORS -eq 0 ]]; then
   echo -e "${GREEN}PREFLIGHT PASSED${NC} - Ready to proceed with installation"
   echo ""
   echo "Next step: Run ./01-install-dependencies.sh"
else
   echo -e "${RED}PREFLIGHT FAILED${NC} - Fix $ERRORS error(s) before continuing"
fi
echo "=============================================="

exit $ERRORS
