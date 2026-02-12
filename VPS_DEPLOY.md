# People We Like Radio - VPS Deployment Guide

Complete copy-paste deployment for a fresh Ubuntu 22.04 VPS.
Produces a publicly reachable radio at **https://radio.peoplewelike.club** with:

- 24/7 AutoDJ with schedule-based playlists (weekday + time-of-day)
- Live RTMP ingest (OBS / Blackmagic) with authentication
- Seamless live/autodj switching without page refresh (relay daemon)
- Video overlay (looping MP4 + audio)
- Enhanced dark-purple web player with chat sidebar
- Let's Encrypt TLS

---

## 0) Variables (edit once, then paste everything below)

```bash
export DOMAIN="radio.peoplewelike.club"
export EMAIL="admin@peoplewelike.club"
export HLS_ROOT="/var/www/hls"
export STREAM_KEY="pwl-live-2024"
export STREAM_PASSWORD='R4d10L1v3Str34m!'
```

---

## 1) System prep + packages + firewall

```bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

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

# Firewall
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 1935/tcp
ufw --force enable

systemctl enable --now nginx

echo "=== Installed versions ==="
nginx -v 2>&1 || true
ffmpeg -version 2>&1 | head -1
liquidsoap --version 2>&1 | head -1
python3 --version
certbot --version 2>&1 || true
```

---

## 2) Users + directory layout + credentials

```bash
set -euo pipefail

# --- System users ---
id radio    &>/dev/null || useradd -r -s /bin/false -d /var/lib/radio radio
id liquidsoap &>/dev/null || useradd -r -s /bin/false -d /var/lib/liquidsoap -g audio liquidsoap
usermod -aG audio radio     2>/dev/null || true
usermod -aG audio liquidsoap 2>/dev/null || true
usermod -aG audio www-data   2>/dev/null || true

# --- Credentials file ---
mkdir -p /etc/radio
cat > /etc/radio/credentials <<EOF
STREAM_KEY=${STREAM_KEY}
STREAM_PASSWORD=${STREAM_PASSWORD}
# RTMP ingest: rtmp://${DOMAIN}:1935/live
# Stream key:  ${STREAM_KEY}
# Full URL:    rtmp://${DOMAIN}:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}
EOF
chmod 600 /etc/radio/credentials

# --- HLS directories ---
mkdir -p "${HLS_ROOT}"/{autodj,live,current,placeholder}
chown -R www-data:www-data "${HLS_ROOT}"
chmod -R 755 "${HLS_ROOT}"

# --- Music library (schedule-based) ---
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

# --- Video loops ---
mkdir -p /var/lib/radio/loops
chown -R radio:audio /var/lib/radio/loops
chmod -R 775 /var/lib/radio/loops

# --- Liquidsoap / metadata ---
mkdir -p /var/lib/liquidsoap /var/log/liquidsoap /etc/liquidsoap
mkdir -p /var/www/radio/data
chown -R liquidsoap:audio /var/lib/liquidsoap /var/log/liquidsoap /etc/liquidsoap
chown -R www-data:www-data /var/www/radio

# --- Runtime / relay state ---
mkdir -p /run/radio /var/lib/radio-hls-relay
chown -R radio:radio /run/radio /var/lib/radio-hls-relay

# --- Web root (separate from any existing av.peoplewelike.club) ---
mkdir -p /var/www/radio.peoplewelike.club
chown -R www-data:www-data /var/www/radio.peoplewelike.club

# --- Initial nowplaying.json ---
cat > /var/www/radio/data/nowplaying.json <<'NPEOF'
{"title":"Starting...","artist":"AutoDJ","mode":"autodj","updated":""}
NPEOF
chown www-data:www-data /var/www/radio/data/nowplaying.json

# --- Placeholder ---
echo "ok" > "${HLS_ROOT}/placeholder/README.txt"

echo "Directory layout created."
```

---

## 3) Nginx: safe default server (prevents wrong-host redirects)

```bash
set -euo pipefail

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
```

---

## 4) Nginx: RTMP config (`/etc/nginx/rtmp.conf`)

```bash
set -euo pipefail

cat > /etc/nginx/rtmp.conf <<'RTMPEOF'
rtmp {
    server {
        listen 1935;
        chunk_size 4096;
        ping 30s;
        ping_timeout 10s;

        # Live ingest (external encoders publish here)
        application live {
            live on;

            # Authentication via on_publish callback
            on_publish http://127.0.0.1:8088/auth;

            # HLS output
            hls on;
            hls_path /var/www/hls/live;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;

            # Notify switch hooks
            exec_publish /usr/local/bin/hls-switch live;
            exec_publish_done /usr/local/bin/hls-switch autodj;

            record off;
        }

        # Internal audio-only feed from Liquidsoap (localhost only)
        application autodj_audio {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny  publish all;
            allow play 127.0.0.1;
            deny  play all;
        }

        # AutoDJ combined video+audio output (localhost only)
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

echo "Created /etc/nginx/rtmp.conf"
```

---

## 5) Nginx: RTMP stats endpoint (localhost:8089)

```bash
set -euo pipefail

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

# Create stat.xsl
mkdir -p /var/www/html
cat > /var/www/html/stat.xsl <<'XSLEOF'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html"/>
<xsl:template match="/">
<html>
<head><title>RTMP Statistics</title></head>
<body>
<h1>RTMP Statistics</h1>
<xsl:apply-templates select="rtmp"/>
</body>
</html>
</xsl:template>
<xsl:template match="rtmp">
<xsl:apply-templates select="server"/>
</xsl:template>
<xsl:template match="server">
<h2>Server</h2>
<xsl:apply-templates select="application"/>
</xsl:template>
<xsl:template match="application">
<h3>Application: <xsl:value-of select="name"/></h3>
<p>Clients: <xsl:value-of select="live/nclients"/></p>
</xsl:template>
</xsl:stylesheet>
XSLEOF
chmod 644 /var/www/html/stat.xsl

echo "Created RTMP stats endpoint on 127.0.0.1:8089"
```

---

## 6) Nginx: RTMP authentication endpoint (localhost:8088)

```bash
set -euo pipefail
source /etc/radio/credentials

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

        # Both must match (011)
        if (\$auth_ok = "011") {
            return 200;
        }

        return 403;
    }
}
AUTHEOF

echo "Created RTMP auth endpoint on 127.0.0.1:8088"
```

---

## 7) Nginx: HTTP vhost for radio + HLS

```bash
set -euo pipefail

cat > /etc/nginx/sites-available/radio.peoplewelike.club.conf <<'RADIOEOF'
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club;

    root /var/www/radio.peoplewelike.club;
    index index.html;

    # HLS streaming
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

    # Now-playing API
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

# Include rtmp.conf in main nginx.conf if not already present
if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf; then
    echo -e "\n# RTMP streaming\ninclude /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
fi

nginx -t
systemctl restart nginx

echo "Nginx vhost configured for ${DOMAIN}"
```

---

## 8) Liquidsoap AutoDJ (schedule-based playlists -> internal RTMP)

```bash
set -euo pipefail

cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ with schedule-based playlists

settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

music_root = "/var/lib/radio/music"

def make_playlist(folder)
  playlist(mode="randomize", reload_mode="watch", folder)
end

# Monday
pl_mon_morning = make_playlist("#{music_root}/monday/morning")
pl_mon_day     = make_playlist("#{music_root}/monday/day")
pl_mon_night   = make_playlist("#{music_root}/monday/night")

# Tuesday
pl_tue_morning = make_playlist("#{music_root}/tuesday/morning")
pl_tue_day     = make_playlist("#{music_root}/tuesday/day")
pl_tue_night   = make_playlist("#{music_root}/tuesday/night")

# Wednesday
pl_wed_morning = make_playlist("#{music_root}/wednesday/morning")
pl_wed_day     = make_playlist("#{music_root}/wednesday/day")
pl_wed_night   = make_playlist("#{music_root}/wednesday/night")

# Thursday
pl_thu_morning = make_playlist("#{music_root}/thursday/morning")
pl_thu_day     = make_playlist("#{music_root}/thursday/day")
pl_thu_night   = make_playlist("#{music_root}/thursday/night")

# Friday
pl_fri_morning = make_playlist("#{music_root}/friday/morning")
pl_fri_day     = make_playlist("#{music_root}/friday/day")
pl_fri_night   = make_playlist("#{music_root}/friday/night")

# Saturday
pl_sat_morning = make_playlist("#{music_root}/saturday/morning")
pl_sat_day     = make_playlist("#{music_root}/saturday/day")
pl_sat_night   = make_playlist("#{music_root}/saturday/night")

# Sunday
pl_sun_morning = make_playlist("#{music_root}/sunday/morning")
pl_sun_day     = make_playlist("#{music_root}/sunday/day")
pl_sun_night   = make_playlist("#{music_root}/sunday/night")

pl_default = make_playlist("#{music_root}/default")
emergency  = blank(id="emergency")

# Schedule: morning 06-12, day 12-18, night 18-06
monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])

radio = crossfade(duration=3.0, fade_in=1.5, fade_out=1.5, scheduled)
radio = normalize(radio)

# Metadata -> JSON
nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  album  = m["album"]
  json_data = '{"title":"#{title}","artist":"#{artist}","album":"#{album}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end

radio = metadata.map(write_nowplaying, radio)

# Output audio to RTMP
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

# Simplified fallback config
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLE'
#!/usr/bin/liquidsoap
# Fallback: scan all music subdirectories
settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

all_music = playlist(mode="randomize", reload_mode="watch", "/var/lib/radio/music")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=3.0, radio)
radio = normalize(radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"
def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end
radio = metadata.map(write_nowplaying, radio)

output.rtmp(
  host="127.0.0.1", port=1935, app="autodj_audio", stream="stream",
  encoder="libfdk_aac", bitrate=128, samplerate=44100, stereo=true, radio
)
LIQSIMPLE

chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq

echo "Liquidsoap configs created."
echo "  Main:     /etc/liquidsoap/radio.liq (schedule-based)"
echo "  Fallback: /etc/liquidsoap/radio-simple.liq (all music)"
```

---

## 9) FFmpeg overlay publisher (autodj-video-overlay)

Loops random MP4 from `/var/lib/radio/loops/` + pulls audio from internal RTMP -> publishes to `autodj` app. Keyframe cadence aligned to 6s HLS fragments.

```bash
set -euo pipefail

cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail

LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

FPS=30
FRAG=6
GOP=$((FPS*FRAG))   # 180 frames
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

# Wait for audio stream
log "Waiting for audio stream..."
for i in {1..60}; do
    if curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio"; then
        log "Audio stream detected"
        break
    fi
    sleep 2
done

# Main loop
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
echo "Created /usr/local/bin/autodj-video-overlay"
```

---

## 10) hls-switch (legacy RTMP publish hook)

```bash
set -euo pipefail

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
  local target="$1"
  ln -sfn "$target" "$CURRENT"
  chown -h www-data:www-data "$CURRENT" 2>/dev/null || true
}

(
  flock -w 10 9
  case "$mode" in
    autodj) do_switch "$AUTODJ_DIR" ;;
    live)
      for i in {1..10}; do
        if has_real_ts "$LIVE_DIR/index.m3u8"; then
          do_switch "$LIVE_DIR"
          exit 0
        fi
        sleep 1
      done
      do_switch "$AUTODJ_DIR"
      ;;
    placeholder) do_switch "$PLACEHOLDER_DIR" ;;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2 ;;
  esac
) 9>"$lock"
EOF

chmod +x /usr/local/bin/hls-switch
echo "Created /usr/local/bin/hls-switch"
```

---

## 11) radio-switchd (live health detection daemon)

```bash
set -euo pipefail

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

latest_ts() {
  awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"
}

mtime_age_s() {
  local now m
  now="$(date +%s)"
  m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
  echo $(( now - m ))
}

live_nclients() {
  curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '
    $0 ~ /<application>/ {inapp=1; name=""}
    inapp && $0 ~ /<name>live<\/name>/ {name="live"}
    name=="live" && $0 ~ /<nclients>/ {
      gsub(/.*<nclients>|<\/nclients>.*/,"",$0); print $0; exit
    }
  ' | tr -d '\r' | awk '{print ($1==""?0:$1)}'
}

set_active() {
  mkdir -p "$ACTIVE_DIR"
  printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"
  mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
}

update_nowplaying_live() {
  if [[ -f "$NOWPLAYING_FILE" ]]; then
    cat > "${NOWPLAYING_FILE}.tmp" <<LIVEEOF
{"title":"LIVE-SHOW","artist":"Live Broadcast","mode":"live","updated":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LIVEEOF
    mv "${NOWPLAYING_FILE}.tmp" "$NOWPLAYING_FILE"
  fi
}

is_live_healthy() {
  local m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  local ts; ts="$(latest_ts "$m3u8")"
  [[ -n "$ts" && -f "$LIVE_DIR/$ts" ]] || return 1

  local age lc
  age="$(mtime_age_s "$m3u8")"
  lc="$(live_nclients || echo 0)"

  [[ "${lc:-0}" -gt 0 ]] && return 0
  [[ "$age" -le 8 ]] && return 0
  return 1
}

mkdir -p "$ACTIVE_DIR"
last=""

while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then
      set_active "live"
      last="live"
      update_nowplaying_live
      log "ACTIVE -> live"
    fi
  else
    if [[ "$last" != "autodj" ]]; then
      set_active "autodj"
      last="autodj"
      log "ACTIVE -> autodj"
    fi
  fi
  sleep 1
done
EOF

chmod +x /usr/local/bin/radio-switchd
echo "Created /usr/local/bin/radio-switchd"
```

---

## 12) radio-hls-relay (seamless switching - the core)

This Python daemon reads `/run/radio/active`, copies segments from the active source into `/hls/current/` with monotonic `seg-N.ts` names and `#EXT-X-DISCONTINUITY` markers on source change. This is what makes switching seamless (no page refresh).

```bash
set -euo pipefail

cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""
Radio HLS Relay - Seamless switching without page refresh
Generates stable /hls/current with monotonic segment IDs
"""
import os, time, json, math, sys

HLS_ROOT = "/var/www/hls"
SRC = {
    "autodj": os.path.join(HLS_ROOT, "autodj"),
    "live":   os.path.join(HLS_ROOT, "live"),
}
OUT_DIR  = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")

ACTIVE_FILE = "/run/radio/active"
STATE_FILE  = "/var/lib/radio-hls-relay/state.json"

WINDOW_SEGMENTS = 10
POLL = 0.5

def read_active():
    try:
        v = open(ACTIVE_FILE, "r").read().strip()
        return v if v in SRC else "autodj"
    except Exception:
        return "autodj"

def parse_m3u8(path):
    segs, dur = [], None
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXTINF:"):
                    try:    dur = float(line.split(":", 1)[1].split(",", 1)[0])
                    except: dur = None
                elif line.startswith("index-") and line.endswith(".ts"):
                    segs.append((dur if dur else 6.0, line))
                    dur = None
    except FileNotFoundError:
        return []
    return segs

def safe_stat(p):
    try:
        st = os.stat(p)
        return int(st.st_mtime), int(st.st_size)
    except Exception:
        return None

def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"next_seq": 0, "map": {}, "window": [], "last_src": None}

def save_state(st):
    tmp = STATE_FILE + ".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_FILE)

def ensure_symlink(link_path, target_path):
    try:
        if os.path.islink(link_path) or os.path.exists(link_path):
            if os.path.islink(link_path) and os.readlink(link_path) == target_path:
                return
            os.unlink(link_path)
    except FileNotFoundError:
        pass
    os.symlink(target_path, link_path)

def write_playlist(window):
    if not window:
        return
    maxdur = max([w["dur"] for w in window] + [6.0])
    target = int(math.ceil(maxdur))
    first_seq = window[0]["seq"]
    lines = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{target}",
        f"#EXT-X-MEDIA-SEQUENCE:{first_seq}",
    ]
    for w in window:
        if w.get("disc"):
            lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},")
        lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8 + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT_M3U8)

def cleanup_symlinks(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window] + ["index.m3u8"])
    try:
        for name in os.listdir(OUT_DIR):
            if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
                try:    os.unlink(os.path.join(OUT_DIR, name))
                except: pass
    except Exception:
        pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Radio HLS Relay started")
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Output: {OUT_M3U8}")

    while True:
        src     = read_active()
        src_dir = SRC[src]
        segs    = parse_m3u8(os.path.join(src_dir, "index.m3u8"))[-WINDOW_SEGMENTS:]
        source_changed = (st.get("last_src") is not None and st.get("last_src") != src)

        for dur, segname in segs:
            src_seg = os.path.join(src_dir, segname)
            ss = safe_stat(src_seg)
            if not ss:
                continue
            mtime, size = ss
            key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]
                st["next_seq"] += 1
                st["map"][key] = {"seq": seq, "dur": float(dur)}
                disc = False
                if source_changed:
                    disc = True
                    source_changed = False
                    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Source switched to: {src}")
                st["window"].append({"seq": seq, "dur": float(dur), "disc": disc})
                ensure_symlink(os.path.join(OUT_DIR, f"seg-{seq}.ts"), src_seg)

        if len(st["window"]) > WINDOW_SEGMENTS:
            st["window"] = st["window"][-WINDOW_SEGMENTS:]

        # Prune old map entries
        if len(st["map"]) > 100:
            keys = list(st["map"].keys())
            for k in keys[:-50]:
                del st["map"][k]

        if st["window"]:
            write_playlist(st["window"])
            cleanup_symlinks(st["window"])

        st["last_src"] = src
        save_state(st)
        time.sleep(POLL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay stopped")
        sys.exit(0)
RELAYEOF

chmod +x /usr/local/bin/radio-hls-relay
echo "Created /usr/local/bin/radio-hls-relay"
```

---

## 13) radio-ctl management utility

```bash
set -euo pipefail

cat > /usr/local/bin/radio-ctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay"

usage() {
    echo "Usage: radio-ctl {start|stop|restart|status|logs}"
    echo "  start   - Start all radio services"
    echo "  stop    - Stop all radio services"
    echo "  restart - Restart all radio services"
    echo "  status  - Show status of all services"
    echo "  logs    - Follow logs from all services"
}

case "${1:-}" in
    start)
        echo "Starting radio services..."
        for svc in $SERVICES; do systemctl start "$svc" || true; done
        sleep 2; systemctl is-active $SERVICES || true
        ;;
    stop)
        echo "Stopping radio services..."
        for svc in $SERVICES; do systemctl stop "$svc" || true; done
        ;;
    restart)
        echo "Restarting radio services..."
        for svc in $SERVICES; do systemctl restart "$svc" || true; done
        sleep 2; systemctl is-active $SERVICES || true
        ;;
    status)
        echo "Radio services:"
        for svc in $SERVICES; do
            s=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            echo "  $svc: $s"
        done
        echo ""
        echo "Active source: $(cat /run/radio/active 2>/dev/null || echo 'unknown')"
        echo "AutoDJ segs:   $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)"
        echo "Live segs:     $(ls /var/www/hls/live/*.ts 2>/dev/null | wc -l)"
        echo "Current segs:  $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)"
        ;;
    logs)
        journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay
        ;;
    *) usage; exit 1 ;;
esac
EOF

chmod +x /usr/local/bin/radio-ctl
echo "Created /usr/local/bin/radio-ctl"
```

---

## 14) Systemd units (4 core services + tmpfiles)

```bash
set -euo pipefail

# --- liquidsoap-autodj ---
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

# --- autodj-video-overlay ---
cat > /etc/systemd/system/autodj-video-overlay.service <<'EOF'
[Unit]
Description=AutoDJ Video Overlay: loop MP4 + AutoDJ audio -> nginx-rtmp autodj
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

# --- radio-switchd ---
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

# --- radio-hls-relay ---
cat > /etc/systemd/system/radio-hls-relay.service <<'EOF'
[Unit]
Description=Radio HLS relay (stable /hls/current playlist for seamless switching)
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

# --- tmpfiles for runtime dirs ---
cat > /etc/tmpfiles.d/radio.conf <<'EOF'
d /run/radio 0755 root root -
d /var/lib/radio-hls-relay 0755 root root -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/radio.conf 2>/dev/null || true

# --- Reload + enable ---
systemctl daemon-reload
systemctl enable liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay

echo "Systemd units created and enabled."
```

---

## 15) Web player (enhanced dark-purple theme)

```bash
set -euo pipefail

cat > /var/www/radio.peoplewelike.club/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>People We Like Radio</title>
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root {
            --bg-dark: #0d0a1a;
            --bg-card: #1a1329;
            --purple-primary: #6b46c1;
            --purple-light: #9f7aea;
            --purple-glow: rgba(107, 70, 193, 0.4);
            --red-live: #e53e3e;
            --red-glow: rgba(229, 62, 62, 0.6);
            --text-primary: #e2e8f0;
            --text-muted: #a0aec0;
            --text-dim: #718096;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-dark); min-height: 100vh; color: var(--text-primary); overflow-x: hidden;
        }
        .bg-animation {
            position: fixed; top: 0; left: 0; width: 100%; height: 100%; z-index: -1;
            background:
                radial-gradient(ellipse at 20% 80%, rgba(107,70,193,0.15) 0%, transparent 50%),
                radial-gradient(ellipse at 80% 20%, rgba(159,122,234,0.1) 0%, transparent 50%);
            animation: bgPulse 8s ease-in-out infinite;
        }
        @keyframes bgPulse { 0%,100%{opacity:1} 50%{opacity:0.7} }
        .container { max-width: 1000px; margin: 0 auto; padding: 20px; }
        header { text-align: center; padding: 30px 20px 20px; }
        .logo {
            font-size: 2em; font-weight: 700;
            background: linear-gradient(135deg, var(--purple-light), var(--purple-primary));
            -webkit-background-clip: text; -webkit-text-fill-color: transparent; background-clip: text;
        }
        .tagline { color: var(--text-dim); font-size: 0.9em; margin-top: 5px; letter-spacing: 2px; text-transform: uppercase; }
        .player-card {
            background: var(--bg-card); border-radius: 16px; overflow: hidden;
            box-shadow: 0 20px 60px rgba(0,0,0,0.5); border: 1px solid rgba(107,70,193,0.2);
        }
        .player-card.live-active { border-color: rgba(229,62,62,0.4); box-shadow: 0 25px 70px rgba(0,0,0,0.6), 0 0 60px var(--red-glow); }
        .video-js { width: 100%; aspect-ratio: 16/9; }
        .now-playing { padding: 20px; background: rgba(0,0,0,0.3); display: flex; align-items: center; gap: 16px; }
        .np-icon {
            width: 50px; height: 50px;
            background: linear-gradient(135deg, var(--purple-primary), var(--purple-light));
            border-radius: 12px; display: flex; align-items: center; justify-content: center; font-size: 24px; flex-shrink: 0;
        }
        .np-info { flex-grow: 1; min-width: 0; }
        .np-label { font-size: 0.7em; text-transform: uppercase; letter-spacing: 2px; color: var(--text-dim); margin-bottom: 4px; }
        .np-title { font-size: 1.1em; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .np-artist { font-size: 0.9em; color: var(--text-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .status-indicator {
            display: flex; align-items: center; gap: 8px; padding: 8px 16px; border-radius: 20px;
            font-size: 0.75em; font-weight: 600; text-transform: uppercase; letter-spacing: 1px;
        }
        .status-indicator.autodj { background: rgba(107,70,193,0.2); border: 1px solid rgba(107,70,193,0.4); color: var(--purple-light); }
        .status-indicator.live {
            background: rgba(229,62,62,0.2); border: 1px solid rgba(229,62,62,0.4); color: var(--red-live);
            animation: liveGlow 1.5s ease-in-out infinite;
        }
        @keyframes liveGlow { 0%,100%{box-shadow:0 0 10px var(--red-glow)} 50%{box-shadow:0 0 25px var(--red-glow)} }
        .status-dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; }
        .status-indicator.live .status-dot { animation: blink 1s infinite; }
        @keyframes blink { 0%,100%{opacity:1} 50%{opacity:0.3} }
        .controls {
            padding: 16px 20px; display: flex; gap: 10px; flex-wrap: wrap; justify-content: center;
            border-top: 1px solid rgba(107,70,193,0.1);
        }
        .btn { padding: 12px 20px; border: none; border-radius: 10px; font-size: 0.9em; font-weight: 600; cursor: pointer; transition: all 0.2s; }
        .btn-primary { background: linear-gradient(135deg, var(--purple-primary), var(--purple-light)); color: white; }
        .btn-primary:hover { transform: translateY(-2px); box-shadow: 0 10px 30px var(--purple-glow); }
        .btn-secondary { background: rgba(107,70,193,0.15); color: var(--purple-light); border: 1px solid rgba(107,70,193,0.3); }
        .btn-secondary:hover { background: rgba(107,70,193,0.25); }
        footer { text-align: center; padding: 30px 20px; color: var(--text-dim); font-size: 0.85em; }
        footer a { color: var(--purple-light); text-decoration: none; }
        .video-js .vjs-big-play-button { background: var(--purple-primary); border: none; border-radius: 50%; width: 80px; height: 80px; line-height: 80px; }
        .video-js:hover .vjs-big-play-button { background: var(--purple-light); }
        .video-js .vjs-control-bar { background: rgba(13,10,26,0.9); }
        .video-js .vjs-play-progress, .video-js .vjs-volume-level { background: var(--purple-primary); }
        @media (max-width: 600px) { .logo { font-size: 1.5em; } .now-playing { flex-direction: column; text-align: center; } }
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
            <video id="radio-player" class="video-js vjs-big-play-centered" controls preload="auto" poster="/poster.jpg">
                <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
            </video>
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
            <div class="controls">
                <button class="btn btn-primary" id="btn-play">Play</button>
                <button class="btn btn-secondary" id="btn-mute">Mute</button>
                <button class="btn btn-secondary" id="btn-fullscreen">Fullscreen</button>
            </div>
        </div>
        <footer>
            <p>&copy; 2024 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></p>
        </footer>
    </div>
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        const player = videojs('radio-player', {
            liveui: true,
            html5: { vhs: { overrideNative: true, smoothQualityChange: true, allowSeeksWithinUnsafeLiveWindow: true }, nativeAudioTracks: false, nativeVideoTracks: false },
            controls: true, autoplay: false, preload: 'auto'
        });
        const btnPlay = document.getElementById('btn-play');
        const btnMute = document.getElementById('btn-mute');
        const btnFs   = document.getElementById('btn-fullscreen');
        btnPlay.addEventListener('click', () => { player.paused() ? player.play() : player.pause(); });
        btnMute.addEventListener('click', () => { player.muted(!player.muted()); btnMute.textContent = player.muted() ? 'Unmute' : 'Mute'; });
        btnFs.addEventListener('click', () => { player.isFullscreen() ? player.exitFullscreen() : player.requestFullscreen(); });
        player.on('play', () => { btnPlay.textContent = 'Pause'; });
        player.on('pause', () => { btnPlay.textContent = 'Play'; });
        player.on('error', () => { setTimeout(() => { player.src({ src: '/hls/current/index.m3u8', type: 'application/x-mpegURL' }); player.load(); }, 3000); });

        const npTitle = document.getElementById('np-title');
        const npArtist = document.getElementById('np-artist');
        const npLabel = document.getElementById('np-label');
        const statusInd = document.getElementById('status-indicator');
        const statusTxt = document.getElementById('status-text');
        const card = document.getElementById('player-card');

        async function updateNP() {
            try {
                const r = await fetch('/api/nowplaying?' + Date.now());
                const d = await r.json();
                if (d.mode === 'live') {
                    npLabel.textContent = 'LIVE BROADCAST';
                    npTitle.textContent = d.title || 'LIVE SHOW';
                    npArtist.textContent = d.artist || '';
                    statusTxt.textContent = 'LIVE';
                    statusInd.className = 'status-indicator live';
                    card.classList.add('live-active');
                } else {
                    npLabel.textContent = 'Now Playing';
                    npTitle.textContent = d.title || 'Unknown Track';
                    npArtist.textContent = d.artist || 'Unknown Artist';
                    statusTxt.textContent = 'AutoDJ';
                    statusInd.className = 'status-indicator autodj';
                    card.classList.remove('live-active');
                }
            } catch(e) {}
        }
        updateNP(); setInterval(updateNP, 5000);
    </script>
</body>
</html>
HTMLEOF

# --- Error pages ---
cat > /var/www/radio.peoplewelike.club/404.html <<'EOF404'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>404</title>
<style>body{font-family:sans-serif;background:#0d0a1a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
h1{font-size:6em;margin:0;background:linear-gradient(135deg,#9f7aea,#6b46c1);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
p{color:#718096;font-size:1.2em}a{color:#9f7aea;text-decoration:none}.e{text-align:center}</style>
</head><body><div class="e"><h1>404</h1><p>Page not found</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF404

cat > /var/www/radio.peoplewelike.club/50x.html <<'EOF50X'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Error</title>
<style>body{font-family:sans-serif;background:#0d0a1a;color:#e2e8f0;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
h1{font-size:4em;margin:0;color:#e53e3e}p{color:#718096;font-size:1.2em}a{color:#9f7aea;text-decoration:none}.e{text-align:center}</style>
</head><body><div class="e"><h1>Server Error</h1><p>Something went wrong.</p><p><a href="/">Back to Radio</a></p></div></body></html>
EOF50X

# --- Poster SVG ---
cat > /var/www/radio.peoplewelike.club/poster.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#0d0a1a"/>
      <stop offset="50%" style="stop-color:#1a1329"/>
      <stop offset="100%" style="stop-color:#0d0a1a"/>
    </linearGradient>
    <linearGradient id="text" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#9f7aea"/>
      <stop offset="100%" style="stop-color:#6b46c1"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <text x="960" y="480" text-anchor="middle" font-family="Arial,sans-serif" font-size="72" font-weight="bold" fill="url(#text)">People We Like</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial,sans-serif" font-size="36" fill="#a0aec0" letter-spacing="8">RADIO</text>
  <text x="960" y="700" text-anchor="middle" font-family="Arial,sans-serif" font-size="24" fill="#718096">Loading stream...</text>
</svg>
SVGEOF

# Convert poster to JPG if ffmpeg available
ffmpeg -y -i /var/www/radio.peoplewelike.club/poster.svg \
       -vf "scale=1920:1080" \
       /var/www/radio.peoplewelike.club/poster.jpg 2>/dev/null || true

chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

echo "Web player deployed to /var/www/radio.peoplewelike.club/"
```

---

## 16) TLS with Let's Encrypt

Requires DNS A records pointing to this VPS for all domains, and port 80 reachable.

```bash
set -euo pipefail

nginx -t
systemctl reload nginx

certbot --nginx \
    -d radio.peoplewelike.club \
    -d stream.peoplewelike.club \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    --redirect \
    --keep-until-expiring

# Auto-renewal
systemctl enable certbot.timer
systemctl start certbot.timer

nginx -t
systemctl reload nginx

echo "TLS configured. HTTPS active for ${DOMAIN}"
```

---

## 17) Start services + verify

```bash
set -euo pipefail

# Final permissions
chown -R www-data:www-data /var/www/hls /var/www/radio /var/www/radio.peoplewelike.club
chmod +x /usr/local/bin/{autodj-video-overlay,radio-switchd,hls-switch,radio-hls-relay,radio-ctl}

# Test nginx
nginx -t

# Start services in order
systemctl restart nginx
sleep 2

systemctl start liquidsoap-autodj
sleep 3

systemctl start autodj-video-overlay
sleep 2

systemctl start radio-switchd
sleep 1

systemctl start radio-hls-relay
sleep 3

echo ""
echo "=== Service Status ==="
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
    s=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    echo "  $svc: $s"
done

echo ""
echo "=== RTMP stat (must return XML) ==="
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 20 || echo "  (not yet responding)"

echo ""
echo "=== HLS folders ==="
ls -lah /var/www/hls/autodj/ | head || echo "  (autodj empty)"
ls -lah /var/www/hls/live/   | head || echo "  (live empty)"
ls -lah /var/www/hls/current/ | head || echo "  (current empty)"

echo ""
echo "=== Active mode ==="
cat /run/radio/active 2>/dev/null || echo "  (not set yet)"

echo ""
echo "=== Relay playlist ==="
head -n 30 /var/www/hls/current/index.m3u8 2>/dev/null || echo "  (not yet - needs music/video files)"
```

---

## 18) Save credentials summary

```bash
set -euo pipefail
source /etc/radio/credentials

cat > /root/radio-info.txt <<INFOEOF
People We Like Radio - Installation Summary
============================================

RADIO URLS
----------
Player:     https://radio.peoplewelike.club/
HLS Stream: https://radio.peoplewelike.club/hls/current/index.m3u8

LIVE STREAMING CREDENTIALS
--------------------------
RTMP Server: rtmp://radio.peoplewelike.club:1935/live
Stream Key:  ${STREAM_KEY}
Password:    ${STREAM_PASSWORD}
Full URL:    rtmp://radio.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}

OBS / Blackmagic Settings:
  Platform: Custom RTMP
  Server:   rtmp://radio.peoplewelike.club:1935/live
  Key:      ${STREAM_KEY}?pwd=${STREAM_PASSWORD}

UPLOAD LOCATIONS
----------------
Music: /var/lib/radio/music/[weekday]/[morning|day|night]/
       /var/lib/radio/music/default/ (fallback)
Loops: /var/lib/radio/loops/ (1920x1080, 30fps, H.264 .mp4)

Day phases (server time):
  morning: 06:00 - 12:00
  day:     12:00 - 18:00
  night:   18:00 - 06:00

MANAGEMENT
----------
radio-ctl start|stop|restart|status|logs

Generated: $(date)
INFOEOF
chmod 600 /root/radio-info.txt

echo ""
echo "========================================"
echo "  DEPLOYMENT COMPLETE"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Upload video loop(s) to /var/lib/radio/loops/*.mp4"
echo "  2. Upload music to /var/lib/radio/music/default/*.mp3"
echo "     (or schedule-based: /var/lib/radio/music/monday/morning/*.mp3 etc.)"
echo "  3. Restart services: radio-ctl restart"
echo "  4. Open https://radio.peoplewelike.club/"
echo ""
echo "Credentials saved to: /root/radio-info.txt"
cat /root/radio-info.txt
```

---

## Operational Notes

- `/var/www/hls/current` is a **directory** managed by the relay daemon. The relay writes `index.m3u8` and symlinks `seg-*.ts` into it. Do not replace it with a symlink.
- If the player "loads forever" on source switch, the relay is either not running or the public URL is not pointing to `/hls/current/index.m3u8`.
- If you see a wrong-host redirect, `00-default.conf` returning `444` is missing or another vhost became default.
- RTMP authentication uses `on_publish` to `127.0.0.1:8088/auth`. The encoder must publish with `?pwd=PASSWORD` appended to the stream key.
- To switch Liquidsoap to the simpler fallback config, edit the systemd unit to use `/etc/liquidsoap/radio-simple.liq` and restart.
