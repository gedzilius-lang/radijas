#!/usr/bin/env bash
###############################################################################
# UPDATE TO CURRENT VERSION
# People We Like Radio - Step 13
#
# This script brings an existing VPS installation up to the current version.
# It is idempotent — safe to run multiple times.  It detects what is already
# installed and only applies missing or outdated components.
#
# What it updates:
#   1. System packages (nginx, ffmpeg, liquidsoap, python3, certbot, utils)
#   2. System users (radio, liquidsoap)
#   3. Directory structure (all paths from 02-create-directories.sh)
#   4. Nginx configs (RTMP, stats, auth, radio vhost)
#   5. Liquidsoap configs (schedule + simple fallback)
#   6. Daemon scripts (autodj-video-overlay, radio-switchd, hls-switch,
#      radio-hls-relay, radio-ctl)
#   7. Systemd services (4 units + tmpfiles)
#   8. Player HTML (Video.js 8 with AutoDJ / Live DJ switching)
#   9. Nowplaying JSON seed
#   10. Permissions
#
# What it does NOT touch:
#   - Music files in /var/lib/radio/music/
#   - Video loops in /var/lib/radio/loops/
#   - SSL certificates (run 07-setup-ssl.sh separately if needed)
#   - /etc/radio/credentials (only creates if missing)
#   - av.peoplewelike.club configs/files
#   - /root/radio-info.txt (only creates if missing)
#
# Run as root:
#   bash install/13-update-to-current.sh
###############################################################################
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[UPDATE]${NC} $*"; }
skip() { echo -e "${CYAN}[SKIP]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      PEOPLE WE LIKE RADIO — UPDATE TO CURRENT              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────
# 0. Pre-checks
# ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

STEP=0
step() {
    STEP=$((STEP+1))
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  Step $STEP: $*${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────────${NC}"
}

###############################################################################
# 1. SYSTEM PACKAGES
###############################################################################
step "System packages"

log "Updating package lists..."
apt-get update -qq 2>/dev/null

install_if_missing() {
    local pkg="$1"
    if dpkg -s "$pkg" &>/dev/null; then
        skip "$pkg already installed"
    else
        log "Installing $pkg..."
        apt-get install -y -qq "$pkg"
    fi
}

install_if_missing "build-essential"
install_if_missing "git"
install_if_missing "curl"
install_if_missing "wget"
install_if_missing "unzip"
install_if_missing "software-properties-common"
install_if_missing "ca-certificates"
install_if_missing "gnupg"
install_if_missing "lsb-release"
install_if_missing "ffmpeg"
install_if_missing "nginx"
install_if_missing "libnginx-mod-rtmp"
install_if_missing "liquidsoap"
install_if_missing "python3"
install_if_missing "python3-pip"
install_if_missing "python3-venv"
install_if_missing "certbot"
install_if_missing "python3-certbot-nginx"
install_if_missing "jq"
install_if_missing "xmlstarlet"
install_if_missing "htop"

###############################################################################
# 2. SYSTEM USERS
###############################################################################
step "System users"

if ! id "radio" &>/dev/null; then
    useradd -r -s /bin/false -d /var/lib/radio radio
    log "Created user: radio"
else
    skip "User 'radio' already exists"
fi

if ! id "liquidsoap" &>/dev/null; then
    useradd -r -s /bin/false -d /var/lib/liquidsoap -g audio liquidsoap 2>/dev/null || \
    useradd -r -s /bin/false -d /var/lib/liquidsoap liquidsoap
    log "Created user: liquidsoap"
else
    skip "User 'liquidsoap' already exists"
fi

usermod -aG audio radio 2>/dev/null || true
usermod -aG audio liquidsoap 2>/dev/null || true
usermod -aG audio www-data 2>/dev/null || true

###############################################################################
# 3. DIRECTORY STRUCTURE
###############################################################################
step "Directory structure"

ensure_dir() {
    local dir="$1"
    local owner="$2"
    local perms="$3"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log "Created $dir"
    fi
    chown "$owner" "$dir"
    chmod "$perms" "$dir"
}

ensure_dir "/var/www/hls"                       "www-data:www-data" "755"
ensure_dir "/var/www/hls/autodj"                "www-data:www-data" "755"
ensure_dir "/var/www/hls/live"                  "www-data:www-data" "755"
ensure_dir "/var/www/hls/current"               "www-data:www-data" "755"
ensure_dir "/var/www/hls/placeholder"           "www-data:www-data" "755"
ensure_dir "/var/www/radio.peoplewelike.club"   "www-data:www-data" "755"
ensure_dir "/var/www/radio/data"                "www-data:www-data" "755"
ensure_dir "/var/lib/radio/music"               "liquidsoap:audio"  "775"
ensure_dir "/var/lib/radio/music/default"       "liquidsoap:audio"  "775"
ensure_dir "/var/lib/radio/loops"               "radio:audio"       "775"
ensure_dir "/var/lib/liquidsoap"                "liquidsoap:audio"  "775"
ensure_dir "/var/log/liquidsoap"                "liquidsoap:audio"  "775"
ensure_dir "/etc/liquidsoap"                    "liquidsoap:audio"  "755"
ensure_dir "/etc/radio"                         "root:root"         "700"
ensure_dir "/run/radio"                         "root:root"         "755"
ensure_dir "/var/lib/radio-hls-relay"           "root:root"         "755"

# Schedule-based music folders
MUSIC_ROOT="/var/lib/radio/music"
for day in monday tuesday wednesday thursday friday saturday sunday; do
    for phase in morning day night; do
        ensure_dir "$MUSIC_ROOT/$day/$phase" "liquidsoap:audio" "775"
    done
done

###############################################################################
# 4. CREDENTIALS (only if missing)
###############################################################################
step "Credentials"

CRED_FILE="/etc/radio/credentials"
if [[ -f "$CRED_FILE" ]]; then
    skip "Credentials file already exists — not overwriting"
else
    STREAM_KEY="pwl-live-2024"
    STREAM_PASSWORD="R4d10L1v3Str34m!"
    cat > "$CRED_FILE" <<EOF
# People We Like Radio - Stream Credentials
STREAM_KEY=${STREAM_KEY}
STREAM_PASSWORD=${STREAM_PASSWORD}
# Full URL: rtmp://ingest.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}
EOF
    chmod 600 "$CRED_FILE"
    log "Created $CRED_FILE with default credentials"
fi

###############################################################################
# 5. NGINX CONFIGURATION
###############################################################################
step "Nginx configuration"

# Source credentials for the auth config
source "$CRED_FILE"

# ── RTMP config ──
log "Writing /etc/nginx/rtmp.conf..."
cat > /etc/nginx/rtmp.conf <<'RTMPEOF'
rtmp {
    server {
        listen 1935;
        chunk_size 4096;
        ping 30s;
        ping_timeout 10s;

        application live {
            live on;
            on_publish http://127.0.0.1:8088/auth;
            hls on;
            hls_path /var/www/hls/live;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;
            exec_publish /usr/local/bin/hls-switch live;
            exec_publish_done /usr/local/bin/hls-switch autodj;
            record off;
        }

        application autodj_audio {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny publish all;
            allow play 127.0.0.1;
            deny play all;
        }

        application autodj {
            live on;
            allow publish 127.0.0.1;
            deny publish all;
            hls on;
            hls_path /var/www/hls/autodj;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;
        }
    }
}
RTMPEOF

# ── RTMP stats ──
log "Writing /etc/nginx/conf.d/rtmp_stat.conf..."
cat > /etc/nginx/conf.d/rtmp_stat.conf <<'STATEOF'
server {
    listen 127.0.0.1:8089;
    location /rtmp_stat {
        rtmp_stat all;
        rtmp_stat_stylesheet /stat.xsl;
    }
    location /stat.xsl {
        root /var/www/html;
    }
}
STATEOF

# ── RTMP auth ──
log "Writing /etc/nginx/conf.d/rtmp_auth.conf..."
cat > /etc/nginx/conf.d/rtmp_auth.conf <<AUTHEOF
server {
    listen 127.0.0.1:8088;
    location /auth {
        set \$auth_ok 0;
        if (\$arg_name = "${STREAM_KEY}") {
            set \$auth_ok "\${auth_ok}1";
        }
        if (\$arg_pwd = "${STREAM_PASSWORD}") {
            set \$auth_ok "\${auth_ok}1";
        }
        if (\$auth_ok = "011") {
            return 200;
        }
        return 403;
    }
}
AUTHEOF

# ── Radio vhost ──
# Only write if the existing file does NOT contain SSL directives
# (certbot would have modified it)
VHOST="/etc/nginx/sites-available/radio.peoplewelike.club.conf"
if [[ -f "$VHOST" ]] && grep -q "ssl_certificate\|listen 443 ssl\|managed by Certbot" "$VHOST" 2>/dev/null; then
    skip "Radio vhost has SSL config (managed by Certbot) — preserving"
else
    log "Writing $VHOST..."
    cat > "$VHOST" <<'RADIOEOF'
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club;

    root /var/www/radio.peoplewelike.club;
    index index.html;

    location /hls {
        alias /var/www/hls;
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, OPTIONS';
        add_header Access-Control-Allow-Headers 'Range,Content-Type';
        add_header Access-Control-Expose-Headers 'Content-Length,Content-Range';

        location ~ \.m3u8$ {
            add_header Cache-Control "no-cache, no-store";
            add_header Access-Control-Allow-Origin *;
        }
        location ~ \.ts$ {
            add_header Cache-Control "max-age=86400";
            add_header Access-Control-Allow-Origin *;
        }
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    location /api/nowplaying {
        alias /var/www/radio/data/nowplaying.json;
        add_header Content-Type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
RADIOEOF
fi

# Symlink
ln -sf "$VHOST" /etc/nginx/sites-enabled/

# Include rtmp.conf in nginx.conf
if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf 2>/dev/null; then
    echo "" >> /etc/nginx/nginx.conf
    echo "# RTMP streaming" >> /etc/nginx/nginx.conf
    echo "include /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
    log "Added RTMP include to nginx.conf"
else
    skip "RTMP include already in nginx.conf"
fi

# stat.xsl
mkdir -p /var/www/html
cat > /var/www/html/stat.xsl <<'XSLEOF'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html"/>
<xsl:template match="/">
<html><head><title>RTMP Statistics</title></head><body>
<h1>RTMP Statistics</h1>
<xsl:apply-templates select="rtmp/server/application"/>
</body></html>
</xsl:template>
<xsl:template match="application">
<h3>Application: <xsl:value-of select="name"/></h3>
<p>Clients: <xsl:value-of select="live/nclients"/></p>
</xsl:template>
</xsl:stylesheet>
XSLEOF

# Test nginx
if nginx -t 2>&1 | grep -q "successful"; then
    log "nginx -t: OK"
else
    warn "nginx -t: FAILED — check config manually"
fi

###############################################################################
# 6. LIQUIDSOAP CONFIGURATION
###############################################################################
step "Liquidsoap configuration"

log "Writing /etc/liquidsoap/radio.liq..."
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ Configuration (Liquidsoap 2.x)

settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

music_root = "/var/lib/radio/music"

monday_morning    = "#{music_root}/monday/morning"
monday_day        = "#{music_root}/monday/day"
monday_night      = "#{music_root}/monday/night"
tuesday_morning   = "#{music_root}/tuesday/morning"
tuesday_day       = "#{music_root}/tuesday/day"
tuesday_night     = "#{music_root}/tuesday/night"
wednesday_morning = "#{music_root}/wednesday/morning"
wednesday_day     = "#{music_root}/wednesday/day"
wednesday_night   = "#{music_root}/wednesday/night"
thursday_morning  = "#{music_root}/thursday/morning"
thursday_day      = "#{music_root}/thursday/day"
thursday_night    = "#{music_root}/thursday/night"
friday_morning    = "#{music_root}/friday/morning"
friday_day        = "#{music_root}/friday/day"
friday_night      = "#{music_root}/friday/night"
saturday_morning  = "#{music_root}/saturday/morning"
saturday_day      = "#{music_root}/saturday/day"
saturday_night    = "#{music_root}/saturday/night"
sunday_morning    = "#{music_root}/sunday/morning"
sunday_day        = "#{music_root}/sunday/day"
sunday_night      = "#{music_root}/sunday/night"
default_folder    = "#{music_root}/default"

def make_playlist(folder)
  playlist(mode="randomize", reload_mode="watch", folder)
end

pl_mon_morning = make_playlist(monday_morning)
pl_mon_day     = make_playlist(monday_day)
pl_mon_night   = make_playlist(monday_night)
pl_tue_morning = make_playlist(tuesday_morning)
pl_tue_day     = make_playlist(tuesday_day)
pl_tue_night   = make_playlist(tuesday_night)
pl_wed_morning = make_playlist(wednesday_morning)
pl_wed_day     = make_playlist(wednesday_day)
pl_wed_night   = make_playlist(wednesday_night)
pl_thu_morning = make_playlist(thursday_morning)
pl_thu_day     = make_playlist(thursday_day)
pl_thu_night   = make_playlist(thursday_night)
pl_fri_morning = make_playlist(friday_morning)
pl_fri_day     = make_playlist(friday_day)
pl_fri_night   = make_playlist(friday_night)
pl_sat_morning = make_playlist(saturday_morning)
pl_sat_day     = make_playlist(saturday_day)
pl_sat_night   = make_playlist(saturday_night)
pl_sun_morning = make_playlist(sunday_morning)
pl_sun_day     = make_playlist(sunday_day)
pl_sun_night   = make_playlist(sunday_night)
pl_default     = make_playlist(default_folder)
emergency      = blank(id="emergency")

monday = switch(track_sensitive=false, [
  ({6h-12h and 1w}, pl_mon_morning),
  ({12h-18h and 1w}, pl_mon_day),
  ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)
])
tuesday = switch(track_sensitive=false, [
  ({6h-12h and 2w}, pl_tue_morning),
  ({12h-18h and 2w}, pl_tue_day),
  ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)
])
wednesday = switch(track_sensitive=false, [
  ({6h-12h and 3w}, pl_wed_morning),
  ({12h-18h and 3w}, pl_wed_day),
  ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)
])
thursday = switch(track_sensitive=false, [
  ({6h-12h and 4w}, pl_thu_morning),
  ({12h-18h and 4w}, pl_thu_day),
  ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)
])
friday = switch(track_sensitive=false, [
  ({6h-12h and 5w}, pl_fri_morning),
  ({12h-18h and 5w}, pl_fri_day),
  ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)
])
saturday = switch(track_sensitive=false, [
  ({6h-12h and 6w}, pl_sat_morning),
  ({12h-18h and 6w}, pl_sat_day),
  ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)
])
sunday = switch(track_sensitive=false, [
  ({6h-12h and 7w}, pl_sun_morning),
  ({12h-18h and 7w}, pl_sun_day),
  ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)
])

scheduled = fallback(track_sensitive=false, [
  monday, tuesday, wednesday, thursday, friday, saturday, sunday,
  pl_default, emergency
])

radio = crossfade(duration=3.0, fade_in=1.5, fade_out=1.5, scheduled)
radio = normalize(radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title = m["title"]
  artist = m["artist"]
  album = m["album"]
  filename = m["filename"]
  json_data = '{"title":"#{title}","artist":"#{artist}","album":"#{album}","filename":"#{filename}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end

radio = metadata.map(write_nowplaying, radio)

output.rtmp(
  host="127.0.0.1",
  port=1935,
  app="autodj_audio",
  stream="stream",
  encoder="libfdk_aac",
  bitrate=128,
  samplerate=44100,
  stereo=true,
  radio
)
LIQEOF

log "Writing /etc/liquidsoap/radio-simple.liq..."
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLEEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - Simplified AutoDJ (fallback)

settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

music_root = "/var/lib/radio/music"
all_music = playlist(mode="randomize", reload_mode="watch", "#{music_root}")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=3.0, radio)
radio = normalize(radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end

radio = metadata.map(write_nowplaying, radio)

output.rtmp(
  host="127.0.0.1",
  port=1935,
  app="autodj_audio",
  stream="stream",
  encoder="libfdk_aac",
  bitrate=128,
  samplerate=44100,
  stereo=true,
  radio
)
LIQSIMPLEEOF

chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq

###############################################################################
# 7. DAEMON SCRIPTS
###############################################################################
step "Daemon scripts"

# Run the existing script if present, otherwise inline
if [[ -f "$SCRIPT_DIR/05-create-scripts.sh" ]]; then
    log "Running 05-create-scripts.sh to install all daemon scripts..."
    bash "$SCRIPT_DIR/05-create-scripts.sh"
else
    warn "05-create-scripts.sh not found — installing inline..."

    # ── autodj-video-overlay ──
    cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail
LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"
FPS=30; FRAG=6; GOP=$((FPS*FRAG)); FORCE_KF="expr:gte(t,n_forced*${FRAG})"
log(){ echo "[$(date -Is)] $*"; }
get_random_loop() {
    local loops=()
    while IFS= read -r -d '' file; do loops+=("$file"); done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
    [[ ${#loops[@]} -eq 0 ]] && { log "ERROR: No .mp4 files in $LOOPS_DIR"; return 1; }
    echo "${loops[$((RANDOM % ${#loops[@]}))]}"
}
log "Waiting for audio stream..."
for i in {1..60}; do curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio" && { log "Audio detected"; break; }; sleep 2; done
while true; do
    LOOP_MP4=$(get_random_loop) || { sleep 10; continue; }
    log "Overlay with: $(basename "$LOOP_MP4")"
    ffmpeg -hide_banner -loglevel warning \
      -re -stream_loop -1 -i "$LOOP_MP4" \
      -thread_queue_size 1024 -i "$AUDIO_IN" \
      -map 0:v:0 -map 1:a:0 \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
      -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
      -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
      -force_key_frames "${FORCE_KF}" \
      -b:v 2500k -maxrate 2500k -bufsize 5000k \
      -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
      -c:a aac -b:a 128k -ar 44100 -ac 2 \
      -muxdelay 0 -muxpreload 0 -flvflags no_duration_filesize \
      -f flv "$OUT" || true
    log "FFmpeg exited, restarting..."; sleep 2
done
OVERLAYEOF
    chmod +x /usr/local/bin/autodj-video-overlay

    # ── radio-switchd ──
    cat > /usr/local/bin/radio-switchd <<'SWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; LIVE_DIR="$HLS_ROOT/live"; AUTODJ_DIR="$HLS_ROOT/autodj"
ACTIVE_DIR="/run/radio"; ACTIVE_FILE="$ACTIVE_DIR/active"
NOWPLAYING_FILE="/var/www/radio/data/nowplaying.json"
RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"
log(){ echo "[$(date -Is)] $*"; }
latest_ts(){ awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"; }
mtime_age_s(){ echo $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )); }
live_nclients(){ curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '$0~/<application>/{a=1;n=""} a&&$0~/<name>live<\/name>/{n="live"} n=="live"&&$0~/<nclients>/{gsub(/.*<nclients>|<\/nclients>.*/,"",$0);print $0;exit}' | tr -d '\r' | awk '{print ($1==""?0:$1)}'; }
set_active(){ mkdir -p "$ACTIVE_DIR"; printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"; mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"; }
update_nowplaying_live(){ [[ -f "$NOWPLAYING_FILE" ]] && { cat > "${NOWPLAYING_FILE}.tmp" <<LIVEEOF
{"title":"LIVE-SHOW","artist":"Live Broadcast","mode":"live","updated":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LIVEEOF
mv "${NOWPLAYING_FILE}.tmp" "$NOWPLAYING_FILE"; }; }
is_live_healthy(){
  local m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  local ts; ts="$(latest_ts "$m3u8")"; [[ -n "$ts" ]] || return 1; [[ -f "$LIVE_DIR/$ts" ]] || return 1
  local age; age="$(mtime_age_s "$m3u8")"; local lc; lc="$(live_nclients || echo 0)"
  [[ "${lc:-0}" -gt 0 ]] && return 0; [[ "$age" -le 8 ]] && return 0; return 1
}
mkdir -p "$ACTIVE_DIR"; last=""
while true; do
  if is_live_healthy; then [[ "$last" != "live" ]] && { set_active "live"; last="live"; update_nowplaying_live; log "ACTIVE -> live"; }
  else [[ "$last" != "autodj" ]] && { set_active "autodj"; last="autodj"; log "ACTIVE -> autodj"; }; fi
  sleep 1
done
SWITCHEOF
    chmod +x /usr/local/bin/radio-switchd

    # ── hls-switch ──
    cat > /usr/local/bin/hls-switch <<'HLSSWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; CURRENT="$HLS_ROOT/current"; mode="${1:-}"; lock="/run/hls-switch.lock"
has_real_ts(){ [[ -f "$1" ]] || return 1; grep -qE '^index-[0-9]+\.ts$' "$1"; }
do_switch(){ ln -sfn "$1" "$CURRENT"; chown -h www-data:www-data "$CURRENT" 2>/dev/null || true; }
( flock -w 10 9
  case "$mode" in
    autodj)  do_switch "$HLS_ROOT/autodj";;
    live)    for i in {1..10}; do has_real_ts "$HLS_ROOT/live/index.m3u8" && { do_switch "$HLS_ROOT/live"; exit 0; }; sleep 1; done; do_switch "$HLS_ROOT/autodj";;
    placeholder) do_switch "$HLS_ROOT/placeholder";;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2;;
  esac
) 9>"$lock"
HLSSWITCHEOF
    chmod +x /usr/local/bin/hls-switch

    # ── radio-hls-relay ──
    cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""Radio HLS Relay - Seamless switching with monotonic segment IDs"""
import os, time, json, math, sys
HLS_ROOT = "/var/www/hls"
SRC = {"autodj": os.path.join(HLS_ROOT, "autodj"), "live": os.path.join(HLS_ROOT, "live")}
OUT_DIR = os.path.join(HLS_ROOT, "current"); OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")
ACTIVE_FILE = "/run/radio/active"; STATE_FILE = "/var/lib/radio-hls-relay/state.json"
WINDOW_SEGMENTS = 10; POLL = 0.5

def read_active():
    try: v = open(ACTIVE_FILE).read().strip(); return v if v in SRC else "autodj"
    except: return "autodj"

def parse_m3u8(path):
    segs = []; dur = None
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXTINF:"):
                    try: dur = float(line.split(":",1)[1].split(",",1)[0])
                    except: dur = None
                elif line.startswith("index-") and line.endswith(".ts"):
                    segs.append((dur or 6.0, line)); dur = None
    except FileNotFoundError: pass
    return segs

def safe_stat(p):
    try: st = os.stat(p); return int(st.st_mtime), int(st.st_size)
    except: return None

def load_state():
    try:
        with open(STATE_FILE) as f: return json.load(f)
    except: return {"next_seq":0,"map":{},"window":[],"last_src":None}

def save_state(st):
    tmp = STATE_FILE+".tmp"; os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp,"w") as f: json.dump(st,f)
    os.replace(tmp, STATE_FILE)

def ensure_symlink(lp, tp):
    try:
        if os.path.islink(lp) or os.path.exists(lp):
            if os.path.islink(lp) and os.readlink(lp)==tp: return
            os.unlink(lp)
    except FileNotFoundError: pass
    os.symlink(tp, lp)

def write_playlist(window):
    if not window: return
    td = int(math.ceil(max([w["dur"] for w in window]+[6.0])))
    fs = window[0]["seq"]
    lines = ["#EXTM3U","#EXT-X-VERSION:3",f"#EXT-X-TARGETDURATION:{td}",f"#EXT-X-MEDIA-SEQUENCE:{fs}"]
    for w in window:
        if w.get("disc"): lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},"); lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8+".tmp"
    with open(tmp,"w") as f: f.write("\n".join(lines)+"\n")
    os.replace(tmp, OUT_M3U8)

def cleanup(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window]+["index.m3u8"])
    try:
        for n in os.listdir(OUT_DIR):
            if n not in keep and n.startswith("seg-") and n.endswith(".ts"):
                try: os.unlink(os.path.join(OUT_DIR,n))
                except: pass
    except: pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True); st = load_state()
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay started → {OUT_M3U8}")
    while True:
        src = read_active(); sd = SRC[src]; segs = parse_m3u8(os.path.join(sd,"index.m3u8"))[-WINDOW_SEGMENTS:]
        sc = st.get("last_src") is not None and st.get("last_src")!=src
        for dur, sn in segs:
            ss = safe_stat(os.path.join(sd,sn))
            if not ss: continue
            mt, sz = ss; key = f"{src}:{sn}:{mt}:{sz}"
            if key not in st["map"]:
                seq = st["next_seq"]; st["next_seq"]+=1; st["map"][key]={"seq":seq,"dur":float(dur)}
                disc = False
                if sc: disc=True; sc=False; print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Switch → {src}")
                st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})
                ensure_symlink(os.path.join(OUT_DIR,f"seg-{seq}.ts"), os.path.join(sd,sn))
        if len(st["window"])>WINDOW_SEGMENTS: st["window"]=st["window"][-WINDOW_SEGMENTS:]
        if len(st["map"])>100:
            for k in list(st["map"].keys())[:-50]: del st["map"][k]
        if st["window"]: write_playlist(st["window"]); cleanup(st["window"])
        st["last_src"]=src; save_state(st); time.sleep(POLL)

if __name__=="__main__":
    try: main()
    except KeyboardInterrupt: print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Stopped"); sys.exit(0)
RELAYEOF
    chmod +x /usr/local/bin/radio-hls-relay

    # ── radio-ctl ──
    cat > /usr/local/bin/radio-ctl <<'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay"
case "${1:-}" in
  start)   for s in $SERVICES; do systemctl start "$s" || true; done;;
  stop)    for s in $SERVICES; do systemctl stop "$s" || true; done;;
  restart) for s in $SERVICES; do systemctl restart "$s" || true; done;;
  status)  for s in $SERVICES; do st=$(systemctl is-active "$s" 2>/dev/null||echo inactive); echo "$s: $st"; done
           echo "Active: $(cat /run/radio/active 2>/dev/null||echo unknown)";;
  logs)    journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay;;
  *)       echo "Usage: radio-ctl {start|stop|restart|status|logs}"; exit 1;;
esac
CTLEOF
    chmod +x /usr/local/bin/radio-ctl
fi

###############################################################################
# 8. SYSTEMD SERVICES
###############################################################################
step "Systemd services"

# Only write units if they don't exist or if force-updating
write_unit() {
    local name="$1"
    local content="$2"
    local unit="/etc/systemd/system/${name}.service"
    log "Writing $unit..."
    echo "$content" > "$unit"
}

write_unit "liquidsoap-autodj" '[Unit]
Description=Liquidsoap AutoDJ (audio-only) -> nginx-rtmp
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=liquidsoap
Group=audio
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/radio.liq
Restart=always
RestartSec=3
Nice=10
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/liquidsoap /var/www/radio/data /var/log/liquidsoap
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target'

# Override for liquidsoap
mkdir -p /etc/systemd/system/liquidsoap-autodj.service.d
cat > /etc/systemd/system/liquidsoap-autodj.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
TimeoutStopSec=10
KillSignal=SIGINT
EOF

write_unit "autodj-video-overlay" '[Unit]
Description=AutoDJ Video Overlay: loop MP4 + AutoDJ audio -> nginx-rtmp autodj
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/autodj-video-overlay
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=10
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target'

write_unit "radio-switchd" '[Unit]
Description=Radio switch daemon (LIVE <-> AutoDJ) every 1s
After=nginx.service
Wants=nginx.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-switchd
Restart=always
RestartSec=1
RuntimeDirectory=radio
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target'

write_unit "radio-hls-relay" '[Unit]
Description=Radio HLS relay (stable /hls/current playlist for seamless switching)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1
StateDirectory=radio-hls-relay
StateDirectoryMode=0755

[Install]
WantedBy=multi-user.target'

# tmpfiles
cat > /etc/tmpfiles.d/radio.conf <<'EOF'
d /run/radio 0755 root root -
d /var/lib/radio-hls-relay 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/radio.conf 2>/dev/null || true

log "Reloading systemd..."
systemctl daemon-reload

for svc in liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
    systemctl enable "$svc" 2>/dev/null || true
done

###############################################################################
# 9. PLAYER HTML (Video.js 8 with AutoDJ/Live DJ switching)
###############################################################################
step "Player HTML"

WEB_ROOT="/var/www/radio.peoplewelike.club"

# Backup existing player
if [[ -f "$WEB_ROOT/index.html" ]]; then
    cp "$WEB_ROOT/index.html" "$WEB_ROOT/index.html.pre-update.$(date +%s)"
    log "Backed up existing player"
fi

# Deploy the latest player using 11-videojs-player-dj-input.sh if available
if [[ -f "$SCRIPT_DIR/11-videojs-player-dj-input.sh" ]]; then
    log "Running 11-videojs-player-dj-input.sh for latest player..."
    bash "$SCRIPT_DIR/11-videojs-player-dj-input.sh"
else
    warn "11-videojs-player-dj-input.sh not found — skipping player update"
    warn "Run it manually to get the latest Video.js player with DJ switching"
fi

# Ensure error pages exist
if [[ ! -f "$WEB_ROOT/404.html" ]]; then
    log "Creating 404.html..."
    cat > "$WEB_ROOT/404.html" <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>404 - People We Like Radio</title>
<style>body{font-family:sans-serif;background:#0d0a1a;min-height:100vh;display:flex;align-items:center;justify-content:center;color:#e2e8f0;margin:0}
.e{text-align:center}h1{font-size:6em;margin:0;color:#9f7aea}p{color:#718096}a{color:#9f7aea;text-decoration:none}</style>
</head><body><div class="e"><h1>404</h1><p>Page not found</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF
fi

if [[ ! -f "$WEB_ROOT/50x.html" ]]; then
    log "Creating 50x.html..."
    cat > "$WEB_ROOT/50x.html" <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Error - People We Like Radio</title>
<style>body{font-family:sans-serif;background:#0d0a1a;min-height:100vh;display:flex;align-items:center;justify-content:center;color:#e2e8f0;margin:0}
.e{text-align:center}h1{font-size:4em;margin:0;color:#e53e3e}p{color:#718096}a{color:#9f7aea;text-decoration:none}</style>
</head><body><div class="e"><h1>Server Error</h1><p>Something went wrong.</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF
fi

# Seed nowplaying.json if missing
NP="/var/www/radio/data/nowplaying.json"
if [[ ! -f "$NP" ]]; then
    log "Creating seed nowplaying.json..."
    echo '{"title":"Starting...","artist":"AutoDJ","mode":"autodj","updated":""}' > "$NP"
    chown www-data:www-data "$NP"
fi

###############################################################################
# 10. FINAL PERMISSIONS
###############################################################################
step "Final permissions"

chown -R www-data:www-data /var/www/hls
chown -R www-data:www-data /var/www/radio
chown -R www-data:www-data "$WEB_ROOT"
chown -R liquidsoap:audio /var/lib/radio/music
chown -R radio:audio /var/lib/radio/loops
chown -R liquidsoap:audio /var/lib/liquidsoap
chown -R liquidsoap:audio /var/log/liquidsoap

chmod +x /usr/local/bin/autodj-video-overlay 2>/dev/null || true
chmod +x /usr/local/bin/radio-switchd 2>/dev/null || true
chmod +x /usr/local/bin/hls-switch 2>/dev/null || true
chmod +x /usr/local/bin/radio-hls-relay 2>/dev/null || true
chmod +x /usr/local/bin/radio-ctl 2>/dev/null || true

log "Permissions set"

###############################################################################
# 11. RESTART SERVICES
###############################################################################
step "Restart services"

log "Restarting nginx..."
if nginx -t 2>&1 | grep -q "successful"; then
    systemctl restart nginx
else
    warn "nginx config test failed — not restarting nginx"
fi

log "Restarting radio services..."
for svc in liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
    systemctl restart "$svc" 2>/dev/null || warn "$svc failed to restart"
    sleep 1
done

sleep 3

###############################################################################
# DONE
###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         UPDATE COMPLETE                                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    if [[ "$status" == "active" ]]; then
        echo -e "  ${GREEN}OK${NC}  $svc"
    else
        echo -e "  ${RED}--${NC}  $svc ($status)"
    fi
done

echo ""
echo "  Active source: $(cat /run/radio/active 2>/dev/null || echo 'pending...')"
echo ""
echo "  Player:  https://radio.peoplewelike.club/"
echo "  HLS:     https://radio.peoplewelike.club/hls/current/index.m3u8"
echo ""
echo "  Run 12-audit-vps.sh to verify the full state."
echo ""
