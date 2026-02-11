#!/usr/bin/env bash
###############################################################################
# VPS AUDIT - Discover what is installed for People We Like Radio
# People We Like Radio - Step 12
#
# This script performs a non-destructive, read-only audit of the VPS to
# determine which components of the radio stack are installed, running,
# configured, or missing.  It produces a summary report at the end.
#
# Run as root:
#   bash install/12-audit-vps.sh
#
# Output format:
#   [OK]    = Component present and healthy
#   [WARN]  = Component present but needs attention
#   [MISS]  = Component missing / not installed
#   [FAIL]  = Component present but broken
###############################################################################
set -euo pipefail

# ── Colours ──────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
miss() { echo -e "  ${RED}[MISS]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
info() { echo -e "  ${CYAN}[INFO]${NC} $*"; }
section() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
}

# Counters for final summary
TOTAL_OK=0
TOTAL_WARN=0
TOTAL_MISS=0
TOTAL_FAIL=0
count_ok()   { TOTAL_OK=$((TOTAL_OK+1)); ok "$@"; }
count_warn() { TOTAL_WARN=$((TOTAL_WARN+1)); warn "$@"; }
count_miss() { TOTAL_MISS=$((TOTAL_MISS+1)); miss "$@"; }
count_fail() { TOTAL_FAIL=$((TOTAL_FAIL+1)); fail "$@"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         PEOPLE WE LIKE RADIO — VPS AUDIT                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Hostname : $(hostname 2>/dev/null || echo unknown)"
echo "  Date     : $(date)"
echo "  Kernel   : $(uname -r)"
echo "  OS       : $(lsb_release -ds 2>/dev/null || cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo unknown)"
echo "  Uptime   : $(uptime -p 2>/dev/null || uptime)"

###############################################################################
# 1. SYSTEM PACKAGES
###############################################################################
section "1. SYSTEM PACKAGES"

# nginx
if command -v nginx &>/dev/null; then
    VER=$(nginx -v 2>&1 | sed 's/.*\///')
    count_ok "nginx $VER"
else
    count_miss "nginx — not installed"
fi

# nginx RTMP module
if nginx -V 2>&1 | grep -q "rtmp" 2>/dev/null; then
    count_ok "libnginx-mod-rtmp loaded"
else
    count_miss "libnginx-mod-rtmp — RTMP module not found"
fi

# ffmpeg
if command -v ffmpeg &>/dev/null; then
    VER=$(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')
    count_ok "ffmpeg $VER"
else
    count_miss "ffmpeg — not installed"
fi

# liquidsoap
if command -v liquidsoap &>/dev/null; then
    VER=$(liquidsoap --version 2>&1 | head -1)
    count_ok "liquidsoap $VER"
else
    count_miss "liquidsoap — not installed"
fi

# python3
if command -v python3 &>/dev/null; then
    VER=$(python3 --version 2>&1 | awk '{print $2}')
    count_ok "python3 $VER"
else
    count_miss "python3 — not installed"
fi

# certbot
if command -v certbot &>/dev/null; then
    VER=$(certbot --version 2>&1 | awk '{print $NF}')
    count_ok "certbot $VER"
else
    count_miss "certbot — not installed"
fi

# jq
if command -v jq &>/dev/null; then
    count_ok "jq $(jq --version 2>&1)"
else
    count_warn "jq — not installed (optional, used by some scripts)"
fi

# xmlstarlet
if command -v xmlstarlet &>/dev/null; then
    count_ok "xmlstarlet installed"
else
    count_warn "xmlstarlet — not installed (optional)"
fi

# curl
if command -v curl &>/dev/null; then
    count_ok "curl installed"
else
    count_miss "curl — not installed"
fi

###############################################################################
# 2. SYSTEM USERS
###############################################################################
section "2. SYSTEM USERS"

if id "radio" &>/dev/null; then
    count_ok "User 'radio' exists ($(id radio 2>/dev/null))"
else
    count_miss "User 'radio' does not exist"
fi

if id "liquidsoap" &>/dev/null; then
    count_ok "User 'liquidsoap' exists ($(id liquidsoap 2>/dev/null))"
else
    count_miss "User 'liquidsoap' does not exist"
fi

if id "www-data" &>/dev/null; then
    count_ok "User 'www-data' exists"
else
    count_warn "User 'www-data' does not exist"
fi

###############################################################################
# 3. DIRECTORY STRUCTURE
###############################################################################
section "3. DIRECTORY STRUCTURE"

check_dir() {
    local dir="$1"
    local desc="$2"
    if [[ -d "$dir" ]]; then
        local owner perms
        owner=$(stat -c '%U:%G' "$dir" 2>/dev/null || echo "?:?")
        perms=$(stat -c '%a' "$dir" 2>/dev/null || echo "???")
        count_ok "$dir ($desc) [$owner $perms]"
    else
        count_miss "$dir ($desc)"
    fi
}

check_dir "/var/www/hls"                          "HLS root"
check_dir "/var/www/hls/autodj"                   "AutoDJ HLS output"
check_dir "/var/www/hls/live"                     "Live HLS output"
check_dir "/var/www/hls/current"                  "Relay output (public)"
check_dir "/var/www/hls/placeholder"              "Placeholder fallback"
check_dir "/var/www/radio.peoplewelike.club"      "Web player root"
check_dir "/var/www/radio/data"                   "Metadata JSON dir"
check_dir "/var/lib/radio/music"                  "Music library"
check_dir "/var/lib/radio/music/default"          "Default music fallback"
check_dir "/var/lib/radio/loops"                  "Video loops"
check_dir "/var/lib/liquidsoap"                   "Liquidsoap state"
check_dir "/var/log/liquidsoap"                   "Liquidsoap logs"
check_dir "/etc/liquidsoap"                       "Liquidsoap config"
check_dir "/etc/radio"                            "Radio credentials"
check_dir "/run/radio"                            "Runtime state"
check_dir "/var/lib/radio-hls-relay"              "HLS relay state"

# Check day/phase music folders
echo ""
info "Checking schedule-based music folders..."
MUSIC_ROOT="/var/lib/radio/music"
MISSING_FOLDERS=0
for day in monday tuesday wednesday thursday friday saturday sunday; do
    for phase in morning day night; do
        if [[ ! -d "$MUSIC_ROOT/$day/$phase" ]]; then
            MISSING_FOLDERS=$((MISSING_FOLDERS+1))
        fi
    done
done
if [[ $MISSING_FOLDERS -eq 0 ]]; then
    count_ok "All 21 schedule folders present (7 days x 3 phases)"
elif [[ $MISSING_FOLDERS -lt 21 ]]; then
    count_warn "$MISSING_FOLDERS of 21 schedule folders missing"
else
    count_miss "All 21 schedule folders missing"
fi

###############################################################################
# 4. CONTENT FILES
###############################################################################
section "4. CONTENT FILES"

# Music files
if [[ -d "$MUSIC_ROOT" ]]; then
    MP3_COUNT=$(find "$MUSIC_ROOT" -type f \( -iname "*.mp3" -o -iname "*.flac" -o -iname "*.ogg" -o -iname "*.wav" \) 2>/dev/null | wc -l)
    if [[ "$MP3_COUNT" -gt 0 ]]; then
        count_ok "$MP3_COUNT music files in $MUSIC_ROOT"
    else
        count_warn "No music files found in $MUSIC_ROOT"
    fi
else
    count_miss "Music directory does not exist"
fi

# Video loops
LOOPS_DIR="/var/lib/radio/loops"
if [[ -d "$LOOPS_DIR" ]]; then
    MP4_COUNT=$(find "$LOOPS_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.webm" \) 2>/dev/null | wc -l)
    if [[ "$MP4_COUNT" -gt 0 ]]; then
        count_ok "$MP4_COUNT video loop(s) in $LOOPS_DIR"
        # Show loop details
        find "$LOOPS_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" \) -exec ls -lh {} \; 2>/dev/null | while read -r line; do
            info "  $line"
        done
    else
        count_warn "No video loop files in $LOOPS_DIR"
    fi
else
    count_miss "Video loops directory does not exist"
fi

# Player files
WEB_ROOT="/var/www/radio.peoplewelike.club"
check_file() {
    local f="$1"
    local desc="$2"
    if [[ -f "$f" ]]; then
        local sz
        sz=$(stat -c '%s' "$f" 2>/dev/null || echo "?")
        count_ok "$f ($desc, ${sz} bytes)"
    else
        count_miss "$f ($desc)"
    fi
}

check_file "$WEB_ROOT/index.html"    "Player HTML"
check_file "$WEB_ROOT/poster.jpg"    "Poster image (JPG)"
check_file "$WEB_ROOT/poster.svg"    "Poster image (SVG)"
check_file "$WEB_ROOT/404.html"      "404 error page"
check_file "$WEB_ROOT/50x.html"      "50x error page"

# Nowplaying JSON
NP="/var/www/radio/data/nowplaying.json"
if [[ -f "$NP" ]]; then
    count_ok "$NP exists"
    info "  Content: $(cat "$NP" 2>/dev/null | head -c 200)"
else
    count_miss "$NP (now-playing metadata)"
fi

###############################################################################
# 5. NGINX CONFIGURATION
###############################################################################
section "5. NGINX CONFIGURATION"

check_file "/etc/nginx/rtmp.conf"                                      "RTMP config"
check_file "/etc/nginx/conf.d/rtmp_stat.conf"                         "RTMP stats endpoint"
check_file "/etc/nginx/conf.d/rtmp_auth.conf"                         "RTMP auth endpoint"
check_file "/etc/nginx/sites-available/radio.peoplewelike.club.conf"  "Radio vhost"

# Symlink check
if [[ -L "/etc/nginx/sites-enabled/radio.peoplewelike.club.conf" ]]; then
    count_ok "Radio vhost symlinked in sites-enabled"
else
    count_miss "Radio vhost NOT symlinked in sites-enabled"
fi

# RTMP include in main nginx.conf
if grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf 2>/dev/null; then
    count_ok "rtmp.conf included in nginx.conf"
else
    count_miss "rtmp.conf NOT included in nginx.conf"
fi

# nginx config test
if nginx -t 2>&1 | grep -q "successful" 2>/dev/null; then
    count_ok "nginx -t: configuration test passed"
else
    count_fail "nginx -t: configuration test FAILED"
fi

###############################################################################
# 6. LIQUIDSOAP CONFIGURATION
###############################################################################
section "6. LIQUIDSOAP CONFIGURATION"

check_file "/etc/liquidsoap/radio.liq"         "Main schedule-based config"
check_file "/etc/liquidsoap/radio-simple.liq"  "Simple fallback config"

###############################################################################
# 7. DAEMON SCRIPTS (/usr/local/bin)
###############################################################################
section "7. DAEMON SCRIPTS (/usr/local/bin)"

for script in autodj-video-overlay radio-switchd hls-switch radio-hls-relay radio-ctl; do
    f="/usr/local/bin/$script"
    if [[ -f "$f" ]]; then
        if [[ -x "$f" ]]; then
            count_ok "$f (executable)"
        else
            count_warn "$f exists but NOT executable"
        fi
    else
        count_miss "$f"
    fi
done

###############################################################################
# 8. SYSTEMD SERVICES
###############################################################################
section "8. SYSTEMD SERVICES"

check_service() {
    local svc="$1"
    local unit="/etc/systemd/system/${svc}.service"

    # Unit file exists?
    if [[ ! -f "$unit" ]]; then
        count_miss "$svc — unit file not found"
        return
    fi

    # Enabled?
    local enabled
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")

    # Active?
    local active
    active=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")

    if [[ "$active" == "active" ]]; then
        count_ok "$svc: ${active}, ${enabled}"
    elif [[ "$enabled" == "enabled" ]]; then
        count_warn "$svc: ${active} (enabled but not running)"
    else
        count_warn "$svc: ${active}, ${enabled}"
    fi

    # Show brief status
    local pid mem
    pid=$(systemctl show -p MainPID "$svc" 2>/dev/null | cut -d= -f2)
    if [[ "$pid" != "0" && -n "$pid" ]]; then
        mem=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.1fMB", $1/1024}')
        info "  PID=$pid  MEM=$mem"
    fi
}

check_service "nginx"
check_service "liquidsoap-autodj"
check_service "autodj-video-overlay"
check_service "radio-switchd"
check_service "radio-hls-relay"

# tmpfiles
if [[ -f /etc/tmpfiles.d/radio.conf ]]; then
    count_ok "/etc/tmpfiles.d/radio.conf (runtime dirs)"
else
    count_miss "/etc/tmpfiles.d/radio.conf"
fi

###############################################################################
# 9. SSL / HTTPS
###############################################################################
section "9. SSL / HTTPS CERTIFICATES"

for domain in radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club; do
    CERT="/etc/letsencrypt/live/$domain/fullchain.pem"
    # Certs may share a single directory, check radio domain as fallback
    CERT_ALT="/etc/letsencrypt/live/radio.peoplewelike.club/fullchain.pem"
    if [[ -f "$CERT" ]]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
        count_ok "$domain cert expires: $EXPIRY"
    elif [[ -f "$CERT_ALT" ]]; then
        EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_ALT" 2>/dev/null | cut -d= -f2)
        count_ok "$domain (shared cert) expires: $EXPIRY"
    else
        count_miss "$domain — no SSL certificate found"
    fi
done

# certbot timer
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    count_ok "certbot.timer active (auto-renewal)"
elif systemctl is-enabled --quiet certbot.timer 2>/dev/null; then
    count_warn "certbot.timer enabled but not active"
else
    count_miss "certbot.timer not enabled"
fi

###############################################################################
# 10. RUNTIME STATE
###############################################################################
section "10. RUNTIME STATE"

# Active source
ACTIVE_FILE="/run/radio/active"
if [[ -f "$ACTIVE_FILE" ]]; then
    SRC=$(cat "$ACTIVE_FILE" 2>/dev/null)
    count_ok "Active source: $SRC (from $ACTIVE_FILE)"
else
    count_miss "$ACTIVE_FILE — switch daemon not writing state"
fi

# HLS relay state
RELAY_STATE="/var/lib/radio-hls-relay/state.json"
if [[ -f "$RELAY_STATE" ]]; then
    SEQ=$(python3 -c "import json; d=json.load(open('$RELAY_STATE')); print(d.get('next_seq',0))" 2>/dev/null || echo "?")
    count_ok "Relay state: next_seq=$SEQ"
else
    count_miss "$RELAY_STATE — relay has not run yet"
fi

# HLS segments
for src in autodj live current; do
    DIR="/var/www/hls/$src"
    if [[ -d "$DIR" ]]; then
        TS_COUNT=$(find "$DIR" -maxdepth 1 -name "*.ts" 2>/dev/null | wc -l)
        M3U8="$DIR/index.m3u8"
        if [[ -f "$M3U8" ]]; then
            AGE=$(( $(date +%s) - $(stat -c %Y "$M3U8" 2>/dev/null || echo 0) ))
            if [[ "$TS_COUNT" -gt 0 && "$AGE" -lt 30 ]]; then
                count_ok "/hls/$src: $TS_COUNT segments, playlist ${AGE}s old"
            elif [[ "$TS_COUNT" -gt 0 ]]; then
                count_warn "/hls/$src: $TS_COUNT segments, playlist ${AGE}s old (stale?)"
            else
                count_warn "/hls/$src: playlist exists but 0 .ts segments"
            fi
        else
            info "/hls/$src: no index.m3u8 ($TS_COUNT .ts files)"
        fi
    fi
done

###############################################################################
# 11. NETWORK / PORTS
###############################################################################
section "11. NETWORK & PORTS"

check_port() {
    local port="$1"
    local desc="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        local proc
        proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1 | sed 's/.*users:(("//' | sed 's/".*//')
        count_ok "Port $port ($desc) — bound by $proc"
    else
        count_miss "Port $port ($desc) — not listening"
    fi
}

check_port 80    "HTTP"
check_port 443   "HTTPS"
check_port 1935  "RTMP ingest"
check_port 8088  "RTMP auth (localhost)"
check_port 8089  "RTMP stats (localhost)"

# RTMP stats reachable?
if curl -fsS --max-time 3 http://127.0.0.1:8089/rtmp_stat &>/dev/null; then
    count_ok "RTMP stats endpoint responds at :8089/rtmp_stat"
else
    count_warn "RTMP stats endpoint not responding at :8089/rtmp_stat"
fi

###############################################################################
# 12. CREDENTIALS
###############################################################################
section "12. CREDENTIALS"

CRED_FILE="/etc/radio/credentials"
if [[ -f "$CRED_FILE" ]]; then
    PERMS=$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo "???")
    if [[ "$PERMS" == "600" ]]; then
        count_ok "$CRED_FILE (perms $PERMS)"
    else
        count_warn "$CRED_FILE exists but perms=$PERMS (should be 600)"
    fi
else
    count_miss "$CRED_FILE"
fi

if [[ -f /root/radio-info.txt ]]; then
    count_ok "/root/radio-info.txt (install summary)"
else
    count_miss "/root/radio-info.txt (install summary)"
fi

###############################################################################
# 13. DISK & RESOURCES
###############################################################################
section "13. DISK & RESOURCES"

AVAIL=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
USED_PCT=$(df / 2>/dev/null | tail -1 | awk '{print $5}')
if [[ "$AVAIL" -gt 10 ]]; then
    count_ok "Disk: ${AVAIL}GB free (${USED_PCT} used)"
else
    count_warn "Disk: ${AVAIL}GB free (${USED_PCT} used) — low space"
fi

MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
if [[ "$MEM_AVAIL" -gt 512 ]]; then
    count_ok "RAM: ${MEM_AVAIL}MB available / ${MEM_TOTAL}MB total"
else
    count_warn "RAM: ${MEM_AVAIL}MB available / ${MEM_TOTAL}MB total — low"
fi

# CPU load
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
info "Load average: $LOAD"

###############################################################################
# 14. PLAYER VERSION CHECK
###############################################################################
section "14. PLAYER VERSION ANALYSIS"

PLAYER="$WEB_ROOT/index.html"
if [[ -f "$PLAYER" ]]; then
    # Detect Video.js version
    VJS_VER=$(grep -oP 'vjs\.zencdn\.net/\K[0-9.]+' "$PLAYER" 2>/dev/null | head -1 || echo "unknown")
    info "Video.js CDN version: $VJS_VER"

    # Detect features in the player
    if grep -q "source-strip\|src-autodj\|src-live" "$PLAYER" 2>/dev/null; then
        count_ok "Player has AutoDJ/Live DJ source strip (v11 style)"
    elif grep -q "status-indicator\|status-badge" "$PLAYER" 2>/dev/null; then
        count_ok "Player has status indicator (v08/v10 style)"
    else
        count_warn "Player missing source mode indicator"
    fi

    if grep -q "switch-overlay" "$PLAYER" 2>/dev/null; then
        count_ok "Player has transition overlay"
    else
        count_warn "Player missing transition overlay (v11 feature)"
    fi

    if grep -q "handlePartialData\|experimentalBufferBasedABR" "$PLAYER" 2>/dev/null; then
        count_ok "Player has advanced VHS options"
    else
        count_warn "Player missing advanced VHS options (v11 feature)"
    fi

    if grep -q "liveTracker\|seekToLiveEdge\|liveTolerance" "$PLAYER" 2>/dev/null; then
        count_ok "Player has live edge seeking"
    else
        count_warn "Player missing live edge seeking (v11 feature)"
    fi

    if grep -q "retryCount\|MAX_RETRIES\|errorRecovering" "$PLAYER" 2>/dev/null; then
        count_ok "Player has retry-based error recovery"
    else
        count_warn "Player has basic error recovery only"
    fi

    if grep -q "chat-card\|chat-messages" "$PLAYER" 2>/dev/null; then
        info "Player includes chat sidebar (v10 feature)"
    fi

    if grep -q "audio-mode\|audio-visualizer" "$PLAYER" 2>/dev/null; then
        info "Player includes audio-only mode (v10 feature)"
    fi

    if grep -q "particles" "$PLAYER" 2>/dev/null; then
        info "Player includes particle animations (v10 feature)"
    fi
else
    count_miss "Player HTML not found at $PLAYER"
fi

###############################################################################
# SUMMARY
###############################################################################
section "AUDIT SUMMARY"

echo ""
echo -e "  ${GREEN}OK   : $TOTAL_OK${NC}"
echo -e "  ${YELLOW}WARN : $TOTAL_WARN${NC}"
echo -e "  ${RED}MISS : $TOTAL_MISS${NC}"
echo -e "  ${RED}FAIL : $TOTAL_FAIL${NC}"
echo ""

TOTAL_ISSUES=$((TOTAL_WARN + TOTAL_MISS + TOTAL_FAIL))

if [[ $TOTAL_ISSUES -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All components healthy. No updates required.${NC}"
elif [[ $TOTAL_FAIL -gt 0 || $TOTAL_MISS -gt 5 ]]; then
    echo -e "  ${RED}${BOLD}Significant gaps detected. Run 13-update-to-current.sh to bring VPS up to date.${NC}"
else
    echo -e "  ${YELLOW}${BOLD}Minor issues found. Run 13-update-to-current.sh to apply updates.${NC}"
fi

echo ""
echo "  Full audit complete. No files were modified."
echo ""
