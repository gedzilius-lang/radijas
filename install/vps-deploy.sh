#!/usr/bin/env bash
###############################################################################
# People We Like Radio - Full VPS Deployment Script
# Usage: bash vps-deploy.sh
#
# Deploys a complete radio station to a fresh Ubuntu 22.04 VPS:
#   - nginx-rtmp (live ingest + autodj HLS)
#   - Liquidsoap AutoDJ (schedule-based playlists)
#   - FFmpeg video overlay (random loop rotation)
#   - Seamless HLS relay (no-refresh source switching)
#   - Dark-purple web player with Video.js
#   - Let's Encrypt TLS
#
# Public endpoint: https://radio.peoplewelike.club/hls/current/index.m3u8
###############################################################################
set -euo pipefail

# ============================================================================
# CONFIGURATION - Edit these before running
# ============================================================================
DOMAIN="${DOMAIN:-radio.peoplewelike.club}"
EMAIL="${EMAIL:-admin@peoplewelike.club}"
HLS_ROOT="${HLS_ROOT:-/var/www/hls}"
STREAM_KEY="${STREAM_KEY:-pwl-live-2024}"
STREAM_PASSWORD="${STREAM_PASSWORD:-R4d10L1v3Str34m!}"

export DOMAIN EMAIL HLS_ROOT STREAM_KEY STREAM_PASSWORD
export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# Helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step_num=0
step() { step_num=$((step_num+1)); echo -e "\n${CYAN}[$step_num] $1${NC}\n"; }
ok()   { echo -e "${GREEN}    OK:${NC} $1"; }
warn() { echo -e "${YELLOW}    WARN:${NC} $1"; }
fail() { echo -e "${RED}    FAIL:${NC} $1"; exit 1; }

# ============================================================================
# Preflight
# ============================================================================
echo ""
echo "========================================================"
echo "  PEOPLE WE LIKE RADIO - VPS DEPLOYMENT"
echo "========================================================"
echo ""
echo "  Domain:     $DOMAIN"
echo "  Email:      $EMAIL"
echo "  HLS root:   $HLS_ROOT"
echo "  Stream key: $STREAM_KEY"
echo ""

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root"
fi

# ============================================================================
step "Installing system packages + firewall"
# ============================================================================
apt-get update -y
apt-get upgrade -y

apt-get install -y \
  build-essential git curl wget unzip \
  software-properties-common apt-transport-https ca-certificates gnupg lsb-release \
  nginx libnginx-mod-rtmp \
  ffmpeg \
  liquidsoap \
  python3 python3-pip python3-venv \
  certbot python3-certbot-nginx \
  jq xmlstarlet htop \
  ufw

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 1935/tcp
ufw --force enable

systemctl enable --now nginx
ok "Packages installed, firewall enabled"

# ============================================================================
step "Creating users + directory layout + credentials"
# ============================================================================
id radio       &>/dev/null || useradd -r -s /bin/false -d /var/lib/radio radio
id liquidsoap  &>/dev/null || useradd -r -s /bin/false -d /var/lib/liquidsoap -g audio liquidsoap
usermod -aG audio radio      2>/dev/null || true
usermod -aG audio liquidsoap 2>/dev/null || true
usermod -aG audio www-data   2>/dev/null || true

mkdir -p /etc/radio
cat > /etc/radio/credentials <<EOF
STREAM_KEY=${STREAM_KEY}
STREAM_PASSWORD=${STREAM_PASSWORD}
EOF
chmod 600 /etc/radio/credentials

mkdir -p "${HLS_ROOT}"/{autodj,live,current,placeholder}
chown -R www-data:www-data "${HLS_ROOT}"
chmod -R 755 "${HLS_ROOT}"

MUSIC_ROOT="/var/lib/radio/music"
mkdir -p "$MUSIC_ROOT"
for day in monday tuesday wednesday thursday friday saturday sunday; do
  for phase in morning day night; do
    mkdir -p "${MUSIC_ROOT}/${day}/${phase}"
  done
done
mkdir -p "${MUSIC_ROOT}/default"
chown -R liquidsoap:audio "$MUSIC_ROOT"
chmod -R 775 "$MUSIC_ROOT"

mkdir -p /var/lib/radio/loops
chown -R radio:audio /var/lib/radio/loops
chmod -R 775 /var/lib/radio/loops

mkdir -p /var/lib/liquidsoap /var/log/liquidsoap /etc/liquidsoap
mkdir -p /var/www/radio/data
chown -R liquidsoap:audio /var/lib/liquidsoap /var/log/liquidsoap /etc/liquidsoap
chown -R www-data:www-data /var/www/radio

mkdir -p /run/radio /var/lib/radio-hls-relay
chown -R radio:radio /run/radio /var/lib/radio-hls-relay

mkdir -p /var/www/radio.peoplewelike.club
chown -R www-data:www-data /var/www/radio.peoplewelike.club

cat > /var/www/radio/data/nowplaying.json <<'NPEOF'
{"title":"Starting...","artist":"AutoDJ","mode":"autodj","updated":""}
NPEOF
chown www-data:www-data /var/www/radio/data/nowplaying.json

echo "ok" > "${HLS_ROOT}/placeholder/README.txt"
ok "Directories, users, credentials created"

# ============================================================================
step "Nginx: safe default server (prevents wrong-host redirects)"
# ============================================================================
cat > /etc/nginx/sites-available/00-default.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}
EOF
ln -sf /etc/nginx/sites-available/00-default.conf /etc/nginx/sites-enabled/00-default.conf
rm -f /etc/nginx/sites-enabled/default || true
nginx -t
systemctl reload nginx
ok "Default server returns 444 for unknown hosts"

# ============================================================================
step "Nginx: RTMP config"
# ============================================================================
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
            deny  publish all;
            allow play 127.0.0.1;
            deny  play all;
        }

        application autodj {
            live on;
            allow publish 127.0.0.1;
            deny  publish all;

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
ok "RTMP config: live (auth), autodj_audio (internal), autodj (internal)"

# ============================================================================
step "Nginx: RTMP stats endpoint (localhost:8089)"
# ============================================================================
cat > /etc/nginx/conf.d/rtmp_stat.conf <<'EOF'
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
EOF

mkdir -p /var/www/html
cat > /var/www/html/stat.xsl <<'XSLEOF'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html"/>
<xsl:template match="/">
<html><head><title>RTMP Statistics</title></head>
<body><h1>RTMP Statistics</h1><xsl:apply-templates select="rtmp"/></body>
</html>
</xsl:template>
<xsl:template match="rtmp"><xsl:apply-templates select="server"/></xsl:template>
<xsl:template match="server"><h2>Server</h2><xsl:apply-templates select="application"/></xsl:template>
<xsl:template match="application">
<h3>Application: <xsl:value-of select="name"/></h3>
<p>Clients: <xsl:value-of select="live/nclients"/></p>
</xsl:template>
</xsl:stylesheet>
XSLEOF
chmod 644 /var/www/html/stat.xsl
ok "RTMP stats on 127.0.0.1:8089/rtmp_stat"

# ============================================================================
step "Nginx: RTMP authentication endpoint (localhost:8088)"
# ============================================================================
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
ok "RTMP auth on 127.0.0.1:8088/auth"

# ============================================================================
step "Nginx: HTTP vhost for radio + HLS"
# ============================================================================
cat > /etc/nginx/sites-available/radio.peoplewelike.club.conf <<'RADIOEOF'
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club;

    root /var/www/radio.peoplewelike.club;
    index index.html;

    location /hls {
        alias /var/www/hls;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods 'GET, OPTIONS' always;
        add_header Access-Control-Allow-Headers 'Range,Content-Type' always;
        add_header Access-Control-Expose-Headers 'Content-Length,Content-Range' always;

        location ~ \.m3u8$ {
            add_header Cache-Control "no-cache, no-store, must-revalidate" always;
            add_header Pragma "no-cache" always;
            add_header Expires "0" always;
            add_header Access-Control-Allow-Origin * always;
        }
        location ~ \.ts$ {
            add_header Cache-Control "max-age=86400" always;
            add_header Access-Control-Allow-Origin * always;
        }
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    location /api/nowplaying {
        alias /var/www/radio/data/nowplaying.json;
        add_header Content-Type application/json always;
        add_header Cache-Control "no-cache, no-store" always;
        add_header Access-Control-Allow-Origin * always;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
RADIOEOF

ln -sf /etc/nginx/sites-available/radio.peoplewelike.club.conf /etc/nginx/sites-enabled/

if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf; then
    echo -e "\n# RTMP streaming\ninclude /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
fi

nginx -t || fail "nginx config test failed"
systemctl restart nginx
ok "Vhost configured for ${DOMAIN}"

# ============================================================================
step "Liquidsoap AutoDJ (schedule-based playlists)"
# ============================================================================
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ (Liquidsoap 2.x compatible)
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

music_root = "/var/lib/radio/music"

def make_playlist(folder)
  playlist(mode="random", reload_mode="watch", folder)
end

pl_mon_morning = make_playlist("#{music_root}/monday/morning")
pl_mon_day     = make_playlist("#{music_root}/monday/day")
pl_mon_night   = make_playlist("#{music_root}/monday/night")
pl_tue_morning = make_playlist("#{music_root}/tuesday/morning")
pl_tue_day     = make_playlist("#{music_root}/tuesday/day")
pl_tue_night   = make_playlist("#{music_root}/tuesday/night")
pl_wed_morning = make_playlist("#{music_root}/wednesday/morning")
pl_wed_day     = make_playlist("#{music_root}/wednesday/day")
pl_wed_night   = make_playlist("#{music_root}/wednesday/night")
pl_thu_morning = make_playlist("#{music_root}/thursday/morning")
pl_thu_day     = make_playlist("#{music_root}/thursday/day")
pl_thu_night   = make_playlist("#{music_root}/thursday/night")
pl_fri_morning = make_playlist("#{music_root}/friday/morning")
pl_fri_day     = make_playlist("#{music_root}/friday/day")
pl_fri_night   = make_playlist("#{music_root}/friday/night")
pl_sat_morning = make_playlist("#{music_root}/saturday/morning")
pl_sat_day     = make_playlist("#{music_root}/saturday/day")
pl_sat_night   = make_playlist("#{music_root}/saturday/night")
pl_sun_morning = make_playlist("#{music_root}/sunday/morning")
pl_sun_day     = make_playlist("#{music_root}/sunday/day")
pl_sun_night   = make_playlist("#{music_root}/sunday/night")

pl_default = make_playlist("#{music_root}/default")
emergency  = blank(id="emergency")

monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])
radio = crossfade(duration=2.0, scheduled)

# Metadata -> JSON (Liquidsoap 2.0.x: use source.on_metadata)
nowplaying_file = "/var/www/radio/data/nowplaying.json"
def handle_metadata(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
end
radio.on_metadata(handle_metadata)

# Output audio-only to RTMP (Liquidsoap 2.x output.url syntax)
output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF

# Simpler fallback config
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLE'
#!/usr/bin/liquidsoap
# Fallback config - scans all music subdirectories (Liquidsoap 2.x)
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

all_music = playlist(mode="random", reload_mode="watch", "/var/lib/radio/music")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=2.0, radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"
def handle_metadata(m)
  title = m["title"]; artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
end
radio.on_metadata(handle_metadata)

output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQSIMPLE

chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq
ok "Liquidsoap configs: radio.liq (schedule), radio-simple.liq (fallback)"

# ============================================================================
step "FFmpeg overlay publisher (autodj-video-overlay)"
# ============================================================================
cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail

LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

FPS=30
FRAG=6
GOP=$((FPS*FRAG))
FORCE_KF="expr:gte(t,n_forced*${FRAG})"

log(){ echo "[$(date -Is)] $*"; }

get_random_loop() {
    local loops=()
    while IFS= read -r -d '' file; do
        loops+=("$file")
    done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
    if [[ ${#loops[@]} -eq 0 ]]; then
        log "ERROR: No .mp4 files in $LOOPS_DIR"
        return 1
    fi
    echo "${loops[$((RANDOM % ${#loops[@]}))]}"
}

log "Waiting for audio stream..."
for i in {1..60}; do
    if curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio"; then
        log "Audio stream detected"; break
    fi
    sleep 2
done

while true; do
    LOOP_MP4=$(get_random_loop) || { sleep 10; continue; }
    log "Starting overlay with loop: $(basename "$LOOP_MP4")"
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
      -muxdelay 0 -muxpreload 0 \
      -flvflags no_duration_filesize \
      -f flv "$OUT" || true
    log "FFmpeg exited, restarting in 2s..."
    sleep 2
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay
ok "autodj-video-overlay script"

# ============================================================================
step "hls-switch (RTMP publish hook)"
# ============================================================================
cat > /usr/local/bin/hls-switch <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"
AUTODJ_DIR="$HLS_ROOT/autodj"
LIVE_DIR="$HLS_ROOT/live"
PLACEHOLDER_DIR="$HLS_ROOT/placeholder"
CURRENT="$HLS_ROOT/current"
mode="${1:-}"
lock="/run/hls-switch.lock"
has_real_ts() {
  local m3u8="$1"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^(index|live|stream)-[0-9]+\.ts$|^index-[0-9]+\.ts$' "$m3u8"
}
do_switch() {
  ln -sfn "$1" "$CURRENT"
  chown -h www-data:www-data "$CURRENT" 2>/dev/null || true
}
(
  flock -w 10 9
  case "$mode" in
    autodj) do_switch "$AUTODJ_DIR" ;;
    live)
      for i in {1..10}; do
        if has_real_ts "$LIVE_DIR/index.m3u8"; then do_switch "$LIVE_DIR"; exit 0; fi
        sleep 1
      done
      do_switch "$AUTODJ_DIR" ;;
    placeholder) do_switch "$PLACEHOLDER_DIR" ;;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2 ;;
  esac
) 9>"$lock"
EOF
chmod +x /usr/local/bin/hls-switch
ok "hls-switch hook"

# ============================================================================
step "radio-switchd (live health detection daemon)"
# ============================================================================
cat > /usr/local/bin/radio-switchd <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"
LIVE_DIR="$HLS_ROOT/live"
ACTIVE_DIR="/run/radio"
ACTIVE_FILE="$ACTIVE_DIR/active"
NOWPLAYING_FILE="/var/www/radio/data/nowplaying.json"
RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"

log(){ echo "[$(date -Is)] $*"; }
latest_ts(){ awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"; }
mtime_age_s(){ local now m; now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"; echo $(( now - m )); }
live_nclients(){
  curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '
    $0 ~ /<application>/ {inapp=1; name=""}
    inapp && $0 ~ /<name>live<\/name>/ {name="live"}
    name=="live" && $0 ~ /<nclients>/ { gsub(/.*<nclients>|<\/nclients>.*/,"",$0); print $0; exit }
  ' | tr -d '\r' | awk '{print ($1==""?0:$1)}'
}
set_active(){ mkdir -p "$ACTIVE_DIR"; printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"; mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"; }
update_nowplaying_live(){
  if [[ -f "$NOWPLAYING_FILE" ]]; then
    printf '{"title":"LIVE-SHOW","artist":"Live Broadcast","mode":"live","updated":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${NOWPLAYING_FILE}.tmp"
    mv "${NOWPLAYING_FILE}.tmp" "$NOWPLAYING_FILE"
  fi
}
is_live_healthy(){
  local m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  local ts; ts="$(latest_ts "$m3u8")"
  [[ -n "$ts" && -f "$LIVE_DIR/$ts" ]] || return 1
  local age lc; age="$(mtime_age_s "$m3u8")"; lc="$(live_nclients || echo 0)"
  [[ "${lc:-0}" -gt 0 ]] && return 0
  [[ "$age" -le 8 ]] && return 0
  return 1
}

mkdir -p "$ACTIVE_DIR"; last=""
while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then set_active "live"; last="live"; update_nowplaying_live; log "ACTIVE -> live"; fi
  else
    if [[ "$last" != "autodj" ]]; then set_active "autodj"; last="autodj"; log "ACTIVE -> autodj"; fi
  fi
  sleep 1
done
EOF
chmod +x /usr/local/bin/radio-switchd
ok "radio-switchd daemon"

# ============================================================================
step "radio-hls-relay (seamless switching core)"
# ============================================================================
cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""Radio HLS Relay - monotonic segment IDs + discontinuity markers"""
import os, time, json, math, sys

HLS_ROOT = "/var/www/hls"
SRC = {"autodj": os.path.join(HLS_ROOT, "autodj"), "live": os.path.join(HLS_ROOT, "live")}
OUT_DIR  = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")
ACTIVE_FILE = "/run/radio/active"
STATE_FILE  = "/var/lib/radio-hls-relay/state.json"
WINDOW_SEGMENTS = 10
POLL = 0.5

def read_active():
    try:
        v = open(ACTIVE_FILE,"r").read().strip()
        return v if v in SRC else "autodj"
    except: return "autodj"

def parse_m3u8(path):
    segs, dur = [], None
    try:
        with open(path,"r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXTINF:"):
                    try: dur = float(line.split(":",1)[1].split(",",1)[0])
                    except: dur = None
                elif line.startswith("index-") and line.endswith(".ts"):
                    segs.append((dur if dur else 6.0, line)); dur = None
    except FileNotFoundError: return []
    return segs

def safe_stat(p):
    try:
        st = os.stat(p); return int(st.st_mtime), int(st.st_size)
    except: return None

def load_state():
    try:
        with open(STATE_FILE,"r") as f: return json.load(f)
    except: return {"next_seq":0,"map":{},"window":[],"last_src":None}

def save_state(st):
    tmp = STATE_FILE+".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
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
    maxdur = max([w["dur"] for w in window]+[6.0])
    target = int(math.ceil(maxdur))
    first_seq = window[0]["seq"]
    lines = ["#EXTM3U","#EXT-X-VERSION:3",f"#EXT-X-TARGETDURATION:{target}",f"#EXT-X-MEDIA-SEQUENCE:{first_seq}"]
    for w in window:
        if w.get("disc"): lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},"); lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8+".tmp"
    with open(tmp,"w") as f: f.write("\n".join(lines)+"\n")
    os.replace(tmp, OUT_M3U8)

def cleanup_symlinks(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window]+["index.m3u8"])
    try:
        for name in os.listdir(OUT_DIR):
            if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
                try: os.unlink(os.path.join(OUT_DIR,name))
                except: pass
    except: pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Radio HLS Relay started")
    while True:
        src = read_active(); src_dir = SRC[src]
        segs = parse_m3u8(os.path.join(src_dir,"index.m3u8"))[-WINDOW_SEGMENTS:]
        source_changed = (st.get("last_src") is not None and st.get("last_src")!=src)
        for dur,segname in segs:
            src_seg = os.path.join(src_dir, segname)
            ss = safe_stat(src_seg)
            if not ss: continue
            mtime,size = ss
            key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]; st["next_seq"]+=1
                st["map"][key]={"seq":seq,"dur":float(dur)}
                disc = False
                if source_changed: disc=True; source_changed=False; print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Source switched to: {src}")
                st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})
                ensure_symlink(os.path.join(OUT_DIR,f"seg-{seq}.ts"), src_seg)
        if len(st["window"])>WINDOW_SEGMENTS: st["window"]=st["window"][-WINDOW_SEGMENTS:]
        if len(st["map"])>100:
            keys=list(st["map"].keys())
            for k in keys[:-50]: del st["map"][k]
        if st["window"]: write_playlist(st["window"]); cleanup_symlinks(st["window"])
        st["last_src"]=src; save_state(st); time.sleep(POLL)

if __name__=="__main__":
    try: main()
    except KeyboardInterrupt: print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay stopped"); sys.exit(0)
RELAYEOF
chmod +x /usr/local/bin/radio-hls-relay
ok "radio-hls-relay daemon"

# ============================================================================
step "radio-ctl management utility"
# ============================================================================
cat > /usr/local/bin/radio-ctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay"
case "${1:-}" in
    start)   echo "Starting...";  for s in $SERVICES; do systemctl start "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
    stop)    echo "Stopping...";  for s in $SERVICES; do systemctl stop "$s"  || true; done ;;
    restart) echo "Restarting..."; for s in $SERVICES; do systemctl restart "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
    status)
        for s in $SERVICES; do echo "  $s: $(systemctl is-active "$s" 2>/dev/null || echo inactive)"; done
        echo ""; echo "Active: $(cat /run/radio/active 2>/dev/null || echo unknown)"
        echo "AutoDJ segs: $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)"
        echo "Current segs: $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)" ;;
    logs) journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay ;;
    *) echo "Usage: radio-ctl {start|stop|restart|status|logs}"; exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/radio-ctl
ok "radio-ctl utility"

# ============================================================================
step "Systemd units (4 services + tmpfiles)"
# ============================================================================
cat > /etc/systemd/system/liquidsoap-autodj.service <<'EOF'
[Unit]
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
KillSignal=SIGINT
TimeoutStopSec=10
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/autodj-video-overlay.service <<'EOF'
[Unit]
Description=AutoDJ Video Overlay: loop MP4 + audio -> nginx-rtmp autodj
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10
[Service]
Type=simple
ExecStart=/usr/local/bin/autodj-video-overlay
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=10
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/radio-switchd.service <<'EOF'
[Unit]
Description=Radio switch daemon (LIVE <-> AutoDJ) every 1s
After=nginx.service
Wants=nginx.service
[Service]
Type=simple
ExecStart=/usr/local/bin/radio-switchd
Restart=always
RestartSec=1
RuntimeDirectory=radio
RuntimeDirectoryMode=0755
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/radio-hls-relay.service <<'EOF'
[Unit]
Description=Radio HLS relay (stable /hls/current for seamless switching)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service
[Service]
Type=simple
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1
StateDirectory=radio-hls-relay
StateDirectoryMode=0755
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/tmpfiles.d/radio.conf <<'EOF'
d /run/radio 0755 root root -
d /var/lib/radio-hls-relay 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/radio.conf 2>/dev/null || true

systemctl daemon-reload
systemctl enable liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay
ok "4 systemd units created + enabled"

# ============================================================================
step "Web player (dark-purple theme)"
# ============================================================================
cat > /var/www/radio.peoplewelike.club/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
    <title>People We Like Radio</title>
    <meta name="description" content="People We Like Radio - 24/7 streaming">
    <meta name="theme-color" content="#0d0a1a">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root{--bg-dark:#0d0a1a;--bg-card:#1a1329;--purple-primary:#6b46c1;--purple-light:#9f7aea;--purple-glow:rgba(107,70,193,0.4);--red-live:#e53e3e;--red-glow:rgba(229,62,62,0.6);--text-primary:#e2e8f0;--text-muted:#a0aec0;--text-dim:#718096}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg-dark);min-height:100vh;min-height:100dvh;color:var(--text-primary);overflow-x:hidden;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
        .bg-animation{position:fixed;top:0;left:0;width:100%;height:100%;z-index:-1;background:radial-gradient(ellipse at 20% 80%,rgba(107,70,193,0.15) 0%,transparent 50%),radial-gradient(ellipse at 80% 20%,rgba(159,122,234,0.1) 0%,transparent 50%);animation:bgPulse 8s ease-in-out infinite}
        @keyframes bgPulse{0%,100%{opacity:1}50%{opacity:0.7}}
        .container{width:100%;max-width:960px;margin:0 auto;padding:clamp(12px,3vw,24px);display:flex;flex-direction:column;min-height:100vh;min-height:100dvh}
        header{text-align:center;padding:clamp(16px,4vw,36px) 0 clamp(12px,2vw,20px)}
        .logo{font-size:clamp(1.5em,5vw,2.2em);font-weight:700;background:linear-gradient(135deg,var(--purple-light),var(--purple-primary));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1.2}
        .tagline{color:var(--text-dim);font-size:clamp(0.7em,2vw,0.9em);margin-top:4px;letter-spacing:3px;text-transform:uppercase}
        .player-card{background:var(--bg-card);border-radius:clamp(8px,2vw,16px);overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,0.5);border:1px solid rgba(107,70,193,0.2);transition:border-color 0.5s,box-shadow 0.5s}
        .player-card.live-active{border-color:rgba(229,62,62,0.4);box-shadow:0 25px 70px rgba(0,0,0,0.6),0 0 60px var(--red-glow)}
        .video-wrapper{position:relative;width:100%;aspect-ratio:16/9;background:#000}
        .video-js{width:100%;height:100%;position:absolute;top:0;left:0}
        .video-js .vjs-big-play-button{background:var(--purple-primary);border:none;border-radius:50%;width:clamp(50px,10vw,80px);height:clamp(50px,10vw,80px);line-height:clamp(50px,10vw,80px);font-size:clamp(1.5em,4vw,2.5em);transition:background 0.2s}
        .video-js:hover .vjs-big-play-button{background:var(--purple-light)}
        .video-js .vjs-control-bar{background:rgba(13,10,26,0.9)}
        .video-js .vjs-play-progress,.video-js .vjs-volume-level{background:var(--purple-primary)}
        .video-js .vjs-slider{background:rgba(107,70,193,0.2)}
        .now-playing{padding:clamp(12px,3vw,20px);background:rgba(0,0,0,0.3);display:flex;align-items:center;gap:clamp(10px,2.5vw,16px)}
        .np-icon{width:clamp(36px,8vw,50px);height:clamp(36px,8vw,50px);background:linear-gradient(135deg,var(--purple-primary),var(--purple-light));border-radius:clamp(8px,1.5vw,12px);display:flex;align-items:center;justify-content:center;font-size:clamp(18px,4vw,24px);flex-shrink:0}
        .np-info{flex-grow:1;min-width:0}
        .np-label{font-size:clamp(0.55em,1.5vw,0.7em);text-transform:uppercase;letter-spacing:2px;color:var(--text-dim);margin-bottom:3px}
        .np-title{font-size:clamp(0.85em,2.5vw,1.1em);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .np-artist{font-size:clamp(0.75em,2vw,0.9em);color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .status-indicator{display:flex;align-items:center;gap:6px;padding:clamp(5px,1.2vw,8px) clamp(10px,2vw,16px);border-radius:20px;font-size:clamp(0.6em,1.5vw,0.75em);font-weight:600;text-transform:uppercase;letter-spacing:1px;flex-shrink:0;white-space:nowrap}
        .status-indicator.autodj{background:rgba(107,70,193,0.2);border:1px solid rgba(107,70,193,0.4);color:var(--purple-light)}
        .status-indicator.live{background:rgba(229,62,62,0.2);border:1px solid rgba(229,62,62,0.4);color:var(--red-live);animation:liveGlow 1.5s ease-in-out infinite}
        @keyframes liveGlow{0%,100%{box-shadow:0 0 10px var(--red-glow)}50%{box-shadow:0 0 25px var(--red-glow)}}
        .status-dot{width:8px;height:8px;border-radius:50%;background:currentColor}
        .status-indicator.live .status-dot{animation:blink 1s infinite}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:0.3}}
        footer{text-align:center;padding:clamp(16px,4vw,30px) 0;color:var(--text-dim);font-size:clamp(0.7em,2vw,0.85em);margin-top:auto}
        footer a{color:var(--purple-light);text-decoration:none}
        footer a:hover{text-decoration:underline}
        @media(max-width:480px){.now-playing{gap:8px}.np-icon{width:32px;height:32px;font-size:16px;border-radius:8px}.status-indicator{padding:4px 8px;font-size:0.6em}}
        @media(max-height:500px) and (orientation:landscape){header{padding:8px 0}.logo{font-size:1.3em}.tagline{display:none}footer{padding:8px 0}}
    </style>
</head>
<body>
    <div class="bg-animation"></div>
    <div class="container">
        <header>
            <div class="logo">People We Like</div>
            <div class="tagline">Radio</div>
        </header>
        <div class="player-card" id="player-card">
            <div class="video-wrapper">
                <video id="radio-player" class="video-js vjs-big-play-centered" controls preload="auto" poster="/poster.jpg">
                    <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                </video>
            </div>
            <div class="now-playing">
                <div class="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Loading...</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
                <div class="status-indicator autodj" id="status-indicator">
                    <span class="status-dot"></span>
                    <span id="status-text">AutoDJ</span>
                </div>
            </div>
        </div>
        <footer>
            <p>&copy; 2025 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></p>
        </footer>
    </div>
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        var player=videojs('radio-player',{liveui:true,html5:{vhs:{overrideNative:true,smoothQualityChange:true,allowSeeksWithinUnsafeLiveWindow:true},nativeAudioTracks:false,nativeVideoTracks:false},controls:true,autoplay:false,preload:'auto',responsive:true,fluid:false});
        player.on('error',function(){setTimeout(function(){player.src({src:'/hls/current/index.m3u8',type:'application/x-mpegURL'});player.load()},3000)});
        var nt=document.getElementById('np-title'),na=document.getElementById('np-artist'),nl=document.getElementById('np-label'),si=document.getElementById('status-indicator'),st=document.getElementById('status-text'),pc=document.getElementById('player-card');
        function u(){fetch('/api/nowplaying?'+Date.now()).then(function(r){return r.json()}).then(function(d){if(d.mode==='live'){nl.textContent='LIVE BROADCAST';nt.textContent=d.title||'LIVE SHOW';na.textContent=d.artist||'';st.textContent='LIVE';si.className='status-indicator live';pc.classList.add('live-active')}else{nl.textContent='Now Playing';nt.textContent=d.title||'Unknown Track';na.textContent=d.artist||'Unknown Artist';st.textContent='AutoDJ';si.className='status-indicator autodj';pc.classList.remove('live-active')}}).catch(function(){})}
        u();setInterval(u,5000);
    </script>
</body>
</html>
HTMLEOF

# Error pages
cat > /var/www/radio.peoplewelike.club/404.html <<'EOF404'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>404</title><style>body{font-family:sans-serif;background:#0d0a1a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}h1{font-size:6em;margin:0;background:linear-gradient(135deg,#9f7aea,#6b46c1);-webkit-background-clip:text;-webkit-text-fill-color:transparent}p{color:#718096;font-size:1.2em}a{color:#9f7aea;text-decoration:none}.e{text-align:center}</style></head><body><div class="e"><h1>404</h1><p>Page not found</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF404

cat > /var/www/radio.peoplewelike.club/50x.html <<'EOF50X'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Error</title><style>body{font-family:sans-serif;background:#0d0a1a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}h1{font-size:4em;margin:0;color:#e53e3e}p{color:#718096;font-size:1.2em}a{color:#9f7aea;text-decoration:none}.e{text-align:center}</style></head><body><div class="e"><h1>Server Error</h1><p>Something went wrong.</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF50X

# Poster
cat > /var/www/radio.peoplewelike.club/poster.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%"><stop offset="0%" style="stop-color:#0d0a1a"/><stop offset="50%" style="stop-color:#1a1329"/><stop offset="100%" style="stop-color:#0d0a1a"/></linearGradient>
    <linearGradient id="text" x1="0%" y1="0%" x2="100%" y2="0%"><stop offset="0%" style="stop-color:#9f7aea"/><stop offset="100%" style="stop-color:#6b46c1"/></linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <text x="960" y="480" text-anchor="middle" font-family="Arial,sans-serif" font-size="72" font-weight="bold" fill="url(#text)">People We Like</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial,sans-serif" font-size="36" fill="#a0aec0" letter-spacing="8">RADIO</text>
  <text x="960" y="700" text-anchor="middle" font-family="Arial,sans-serif" font-size="24" fill="#718096">Loading stream...</text>
</svg>
SVGEOF
ffmpeg -y -i /var/www/radio.peoplewelike.club/poster.svg -vf "scale=1920:1080" /var/www/radio.peoplewelike.club/poster.jpg 2>/dev/null || true

chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club
ok "Web player deployed"

# ============================================================================
step "TLS with Let's Encrypt"
# ============================================================================
nginx -t || fail "nginx config broken before certbot"
systemctl reload nginx

certbot --nginx \
    -d radio.peoplewelike.club \
    -d stream.peoplewelike.club \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    --redirect \
    --keep-until-expiring || warn "certbot failed - check DNS A records point to this VPS and port 80 is reachable"

systemctl enable certbot.timer 2>/dev/null || true
systemctl start certbot.timer 2>/dev/null || true

nginx -t && systemctl reload nginx
ok "TLS configured (if certbot succeeded)"

# ============================================================================
step "Starting all services + verification"
# ============================================================================
chown -R www-data:www-data /var/www/hls /var/www/radio /var/www/radio.peoplewelike.club
chmod +x /usr/local/bin/{autodj-video-overlay,radio-switchd,hls-switch,radio-hls-relay,radio-ctl}

nginx -t || fail "nginx config broken"
systemctl restart nginx; sleep 2
systemctl start liquidsoap-autodj; sleep 3
systemctl start autodj-video-overlay; sleep 2
systemctl start radio-switchd; sleep 1
systemctl start radio-hls-relay; sleep 3

echo ""
echo "=== Service Status ==="
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
    s=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    if [[ "$s" == "active" ]]; then ok "$svc: running"; else warn "$svc: $s"; fi
done

echo ""
echo "=== RTMP Stats ==="
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 10 || warn "RTMP stats not responding yet"

echo ""
echo "=== Active Mode ==="
cat /run/radio/active 2>/dev/null || echo "  (not set yet)"

# ============================================================================
step "Saving credentials summary"
# ============================================================================
cat > /root/radio-info.txt <<INFOEOF
People We Like Radio - Installation Summary
============================================

URLS
----
Player:     https://radio.peoplewelike.club/
HLS Stream: https://radio.peoplewelike.club/hls/current/index.m3u8

LIVE STREAMING
--------------
RTMP Server: rtmp://radio.peoplewelike.club:1935/live
Stream Key:  ${STREAM_KEY}
Password:    ${STREAM_PASSWORD}
Full URL:    rtmp://radio.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}

OBS / Blackmagic:
  Server: rtmp://radio.peoplewelike.club:1935/live
  Key:    ${STREAM_KEY}?pwd=${STREAM_PASSWORD}

UPLOADS
-------
Music: /var/lib/radio/music/[weekday]/[morning|day|night]/ or default/
Loops: /var/lib/radio/loops/*.mp4 (1920x1080, 30fps, H.264)

MANAGEMENT
----------
radio-ctl start|stop|restart|status|logs

Generated: $(date)
INFOEOF
chmod 600 /root/radio-info.txt

echo ""
echo "========================================================"
echo -e "  ${GREEN}DEPLOYMENT COMPLETE${NC}"
echo "========================================================"
echo ""
echo "  Next steps:"
echo "    1. Upload video loop(s): scp loop.mp4 root@${DOMAIN}:/var/lib/radio/loops/"
echo "    2. Upload music:         scp *.mp3 root@${DOMAIN}:/var/lib/radio/music/default/"
echo "    3. Restart services:     radio-ctl restart"
echo "    4. Open:                 https://${DOMAIN}/"
echo ""
echo "  Credentials: /root/radio-info.txt"
echo ""
cat /root/radio-info.txt
