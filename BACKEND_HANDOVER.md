# People We Like Radio — Backend Technical Handover

**Status:** ✅ WORKING
**Last Updated:** January 2026
**Server:** srv1178155 (72.60.181.89)
**OS:** Ubuntu 22.04 LTS

---

## 1. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PEOPLE WE LIKE RADIO                               │
│                         Architecture Diagram                                 │
└─────────────────────────────────────────────────────────────────────────────┘

    ┌─────────────────┐         ┌─────────────────┐
    │   AutoDJ        │         │   Live Input    │
    │   (ffmpeg)      │         │   (Blackmagic/  │
    │                 │         │    OBS)         │
    │  Video Loops    │         │                 │
    │  + MP3 Audio    │         │                 │
    └────────┬────────┘         └────────┬────────┘
             │                           │
             │ RTMP                       │ RTMP
             │ localhost:1935            │ :1935/live/likewe
             │ /autodj/index             │
             ▼                           ▼
    ┌─────────────────────────────────────────────────────────────────┐
    │                      NGINX-RTMP (Port 1935)                      │
    │  ┌─────────────────────┐      ┌─────────────────────────────┐   │
    │  │ application autodj  │      │ application live            │   │
    │  │ (localhost only)    │      │ (external, authenticated)   │   │
    │  │                     │      │                             │   │
    │  │ HLS → /hls/autodj/  │      │ HLS → /hls/live/            │   │
    │  └─────────────────────┘      └─────────────────────────────┘   │
    └──────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────────────────────────────┐
    │                      SWITCH DAEMON                               │
    │                   /usr/local/bin/radio-switchd                   │
    │                                                                  │
    │   • Checks /hls/live/index.m3u8 freshness every 1 second        │
    │   • Writes "live" or "autodj" to /run/radio/active              │
    └──────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────────────────────────────┐
    │                      HLS RELAY DAEMON                            │
    │                   /usr/local/bin/radio-hls-relay                 │
    │                                                                  │
    │   • Reads /run/radio/active to know current source              │
    │   • COPIES segments to /hls/current/ (not symlinks)             │
    │   • Creates stable playlist with monotonic sequence IDs          │
    │   • Inserts #EXT-X-DISCONTINUITY on source switch               │
    │   • Enables seamless switching WITHOUT page refresh             │
    └──────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────────────────────────────┐
    │                      NGINX HTTP (Port 443)                       │
    │                                                                  │
    │   https://radio.peoplewelike.club/hls/current/index.m3u8        │
    │                              │                                   │
    │                              ▼                                   │
    │                      ┌──────────────┐                           │
    │                      │  Web Player  │                           │
    │                      │  (Video.js)  │                           │
    │                      └──────────────┘                           │
    └─────────────────────────────────────────────────────────────────┘
```

---

## 2. Services (All Active)

| Service | Status | Description |
|---------|--------|-------------|
| `autodj-stream` | ✅ Active | FFmpeg-based AutoDJ (video + audio) |
| `radio-switchd` | ✅ Active | Live/AutoDJ detection daemon |
| `radio-hls-relay` | ✅ Active | Seamless HLS relay (copy mode) |
| `nginx` | ✅ Active | Web server + RTMP server |
| `radio-cleanup.timer` | ✅ Active | Cleanup old segments every 5 min |

### 2.1 autodj-stream.service

**Script:** `/usr/local/bin/autodj-stream`

```bash
#!/usr/bin/env bash
set -euo pipefail

LOOPS_DIR="/var/lib/radio/loops"
MUSIC_DIR="/var/lib/radio/music/default"
NOWPLAYING="/var/www/radio/data/nowplaying.json"
OUT="rtmp://127.0.0.1:1935/autodj/index"

# 1080p @ 30fps settings
FPS=30
FRAG=6
GOP=$((FPS*FRAG))

log(){ echo "[$(date -Is)] $*"; }

get_random_file() {
    local dir="$1"
    local ext="$2"
    shuf -n1 -e "$dir"/*."$ext" 2>/dev/null || true
}

update_nowplaying() {
    local file="$1"
    local basename=$(basename "$file")
    local title="${basename%.*}"
    local artist=""
    if [[ "$title" == *" - "* ]]; then
        artist="${title%% - *}"
        title="${title#* - }"
    fi
    printf '{"title":"%s","artist":"%s","mode":"autodj"}' "$title" "$artist" > "$NOWPLAYING"
}

log "AutoDJ starting (1080p@30fps)..."

while true; do
    LOOP=$(get_random_file "$LOOPS_DIR" "mp4")
    MUSIC=$(get_random_file "$MUSIC_DIR" "mp3")

    [[ -z "$LOOP" ]] && { log "No loops"; sleep 5; continue; }
    [[ -z "$MUSIC" ]] && { log "No music"; sleep 5; continue; }

    DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$MUSIC" 2>/dev/null | cut -d. -f1)
    [[ -z "$DURATION" || "$DURATION" -lt 10 ]] && DURATION=180

    update_nowplaying "$MUSIC"
    log "Playing: $(basename "$MUSIC") (${DURATION}s)"

    ffmpeg -hide_banner -loglevel error \
      -re -stream_loop -1 -i "$LOOP" \
      -re -i "$MUSIC" \
      -map 0:v:0 -map 1:a:0 \
      -t "$DURATION" \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
      -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
      -r ${FPS} -g ${GOP} -keyint_min ${GOP} -sc_threshold 0 \
      -b:v 2500k -maxrate 2500k -bufsize 5000k \
      -c:a aac -b:a 128k -ar 44100 -ac 2 \
      -flvflags no_duration_filesize \
      -f flv "$OUT" 2>&1 || true

    sleep 0.5
done
```

### 2.2 radio-switchd.service

**Script:** `/usr/local/bin/radio-switchd`

```bash
#!/usr/bin/env bash
set -euo pipefail

LIVE_M3U8="/var/www/hls/live/index.m3u8"
ACTIVE="/run/radio/active"
NOWPLAYING="/var/www/radio/data/nowplaying.json"

mkdir -p /run/radio
last=""

is_live() {
    [[ ! -f "$LIVE_M3U8" ]] && return 1
    local age=$(( $(date +%s) - $(stat -c %Y "$LIVE_M3U8" 2>/dev/null || echo 0) ))
    [[ $age -gt 10 ]] && return 1
    grep -qE '^index-[0-9]+\.ts' "$LIVE_M3U8" 2>/dev/null
}

while true; do
    if is_live; then
        if [[ "$last" != "live" ]]; then
            echo "live" > "$ACTIVE"
            echo '{"title":"LIVE","artist":"Live Broadcast","mode":"live"}' > "$NOWPLAYING"
            last="live"
        fi
    else
        if [[ "$last" != "autodj" ]]; then
            echo "autodj" > "$ACTIVE"
            last="autodj"
        fi
    fi
    sleep 1
done
```

### 2.3 radio-hls-relay.service

**Script:** `/usr/local/bin/radio-hls-relay` (Python)

Key features:
- **Copy mode** (not symlinks) - copies segments to /hls/current/
- Maintains 8-segment window
- Inserts `#EXT-X-DISCONTINUITY` on source switch
- Monotonic sequence IDs for seamless player experience

---

## 3. Configuration Files

### 3.1 RTMP Configuration
**File:** `/etc/nginx/rtmp.conf`

```nginx
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
```

### 3.2 RTMP Authentication
**File:** `/etc/nginx/conf.d/rtmp_auth.conf`

```nginx
server {
    listen 127.0.0.1:8088;
    location /auth {
        if ($arg_name = "likewe") {
            return 200;
        }
        if ($arg_name = "") {
            return 200;
        }
        return 403;
    }
}
```

### 3.3 Web Server (HTTPS)
**File:** `/etc/nginx/sites-available/radio.peoplewelike.club.conf`

```nginx
server {
    listen 443 ssl;
    server_name radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club;

    ssl_certificate /etc/letsencrypt/live/radio.peoplewelike.club/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/radio.peoplewelike.club/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    root /var/www/radio.peoplewelike.club;
    index index.html;

    location /hls {
        alias /var/www/hls;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, OPTIONS";
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    location /api/nowplaying {
        alias /var/www/radio/data/nowplaying.json;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}

server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club;
    return 301 https://$host$request_uri;
}
```

---

## 4. Directory Structure

```
/var/www/hls/
├── autodj/                    # AutoDJ HLS output (nginx-rtmp writes here)
│   ├── index.m3u8
│   └── index-*.ts
├── live/                      # Live stream HLS output
│   ├── index.m3u8
│   └── index-*.ts
└── current/                   # Relay output (COPIED segments, served to players)
    ├── index.m3u8
    └── seg-*.ts

/var/lib/radio/
├── music/
│   └── default/               # MP3 files for AutoDJ
└── loops/                     # MP4 video loops (1080p, 30fps, H.264)

/var/www/radio/data/
└── nowplaying.json            # Current track metadata

/run/radio/
└── active                     # Current source: "live" or "autodj"

/usr/local/bin/
├── autodj-stream              # AutoDJ ffmpeg script
├── radio-switchd              # Switch detection daemon
├── radio-hls-relay            # HLS relay daemon (Python, copy mode)
├── hls-switch                 # RTMP hook script
├── radio-cleanup              # Cleanup script
└── radio-ctl                  # Management utility
```

---

## 5. Stream Credentials

| Setting | Value |
|---------|-------|
| **RTMP Server** | `rtmp://ingest.peoplewelike.club:1935/live` |
| **Stream Key** | `likewe` |
| **Password** | *(none required)* |

### Encoder Setup

**Blackmagic Web Presenter:**
```
Platform: Custom RTMP
Server:   rtmp://ingest.peoplewelike.club:1935/live
Key:      likewe
```

**OBS Studio:**
```
Service:    Custom
Server:     rtmp://ingest.peoplewelike.club:1935/live
Stream Key: likewe
```

---

## 6. URLs

| Purpose | URL |
|---------|-----|
| **Web Player** | https://radio.peoplewelike.club/ |
| **HLS Stream** | https://radio.peoplewelike.club/hls/current/index.m3u8 |
| **Now Playing API** | https://radio.peoplewelike.club/api/nowplaying |

---

## 7. Management Commands

```bash
# Control all services
radio-ctl start    # Start all
radio-ctl stop     # Stop all
radio-ctl restart  # Restart all
radio-ctl status   # Show status
radio-ctl logs     # Follow logs

# Individual services
systemctl status autodj-stream radio-switchd radio-hls-relay

# View logs
journalctl -u autodj-stream -f
journalctl -u radio-switchd -f
journalctl -u radio-hls-relay -f

# Check active source
cat /run/radio/active

# Check HLS segments
ls -la /var/www/hls/current/
```

---

## 8. How Switching Works

### Live Stream Starts:
1. Encoder publishes to `rtmp://ingest.../live/likewe`
2. nginx-rtmp authenticates and accepts stream
3. nginx-rtmp writes HLS to `/var/www/hls/live/`
4. `radio-switchd` detects fresh live playlist (< 10 seconds old)
5. `radio-switchd` writes `live` to `/run/radio/active`
6. `radio-hls-relay` reads active, switches to live source
7. `radio-hls-relay` inserts `#EXT-X-DISCONTINUITY`
8. Player continues seamlessly (no refresh needed)

### Live Stream Stops:
1. Encoder disconnects
2. `/var/www/hls/live/index.m3u8` becomes stale (> 10 seconds)
3. `radio-switchd` detects, writes `autodj` to `/run/radio/active`
4. `radio-hls-relay` switches back to autodj source
5. Player continues seamlessly

---

## 9. Upload Locations

### Music Files (.mp3)
```
/var/lib/radio/music/default/
```
- Any MP3 format supported
- Filename format: `Artist - Title.mp3` (for metadata extraction)
- Files are randomly shuffled

### Video Loops (.mp4)
```
/var/lib/radio/loops/
```
- Resolution: 1920x1080
- Frame rate: 30fps
- Codec: H.264
- Multiple files = random rotation

### After Upload
```bash
chown -R root:audio /var/lib/radio/music/
chown -R root:audio /var/lib/radio/loops/
chmod -R 775 /var/lib/radio/music/
chmod -R 775 /var/lib/radio/loops/
systemctl restart autodj-stream
```

---

## 10. Troubleshooting

### Check Everything
```bash
radio-ctl status
cat /run/radio/active
ls -la /var/www/hls/current/
curl -s https://radio.peoplewelike.club/hls/current/index.m3u8 | head
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Player spinning | Check `radio-hls-relay`: `journalctl -u radio-hls-relay -f` |
| No segments | Check `autodj-stream`: `journalctl -u autodj-stream -f` |
| Live not detected | Check playlist age: `stat /var/www/hls/live/index.m3u8` |
| 404 on HLS | Reload nginx: `nginx -t && systemctl reload nginx` |
| Encoder "cache" | Check port 1935: `nc -zv 72.60.181.89 1935` |

### Restart All
```bash
systemctl restart autodj-stream radio-switchd radio-hls-relay nginx
```

---

## 11. Maintenance

### Cleanup Timer
- Runs every 5 minutes via `radio-cleanup.timer`
- Removes segments older than 5 minutes
- Truncates large log files

### Log Rotation
- Configured in `/etc/logrotate.d/radio`
- Daily rotation, 3 days retention

### SSL Certificates
- Auto-renewed via `certbot.timer`
- Certificates in `/etc/letsencrypt/live/radio.peoplewelike.club/`

---

## 12. Coexistence with av.peoplewelike.club

**DO NOT MODIFY** (separate Illuminatics Pitch site):
```
/var/www/av.peoplewelike.club/
/opt/avpitch/
/etc/nginx/sites-available/av.peoplewelike.club.conf
/usr/local/bin/avpitch-update
```

---

## 13. Quick Reference

```
┌─────────────────────────────────────────────────────────────────┐
│                    QUICK REFERENCE                               │
├─────────────────────────────────────────────────────────────────┤
│  STREAM KEY:     likewe                                         │
│  RTMP SERVER:    rtmp://ingest.peoplewelike.club:1935/live      │
│  HLS URL:        https://radio.peoplewelike.club/hls/current/   │
│  PLAYER:         https://radio.peoplewelike.club/               │
│                                                                  │
│  UPLOAD MUSIC:   /var/lib/radio/music/default/                  │
│  UPLOAD LOOPS:   /var/lib/radio/loops/                          │
│                                                                  │
│  CHECK STATUS:   radio-ctl status                               │
│  VIEW LOGS:      radio-ctl logs                                 │
│  RESTART ALL:    radio-ctl restart                              │
│                                                                  │
│  ACTIVE SOURCE:  cat /run/radio/active                          │
└─────────────────────────────────────────────────────────────────┘
```

---

*Document updated: January 2026*
*Configuration verified working: AutoDJ ✅ | Live ✅ | Switching ✅*
