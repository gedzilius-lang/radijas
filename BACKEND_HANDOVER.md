# People We Like Radio — Backend Technical Handover

**Date:** January 2026
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
    │   • Polls RTMP stats every 1 second                             │
    │   • Detects if live stream is active                            │
    │   • Writes "live" or "autodj" to /run/radio/active              │
    └──────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
    ┌─────────────────────────────────────────────────────────────────┐
    │                      HLS RELAY DAEMON                            │
    │                   /usr/local/bin/radio-hls-relay                 │
    │                                                                  │
    │   • Reads /run/radio/active to know current source              │
    │   • Creates stable /hls/current/ with monotonic segment IDs     │
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

## 2. Services

### 2.1 autodj-stream.service
**Purpose:** Generates 24/7 AutoDJ stream (video + audio) via ffmpeg

```
Service:     autodj-stream.service
Script:      /usr/local/bin/autodj-stream
User:        root
Restart:     always
```

**What it does:**
- Picks random video loop from `/var/lib/radio/loops/`
- Picks random MP3 from `/var/lib/radio/music/default/`
- Combines video (looped) + audio (one song at a time)
- Outputs to `rtmp://127.0.0.1:1935/autodj/index`
- Updates now-playing metadata in `/var/www/radio/data/nowplaying.json`
- When song ends, picks new random song and continues

### 2.2 radio-switchd.service
**Purpose:** Detects live input and triggers source switching

```
Service:     radio-switchd.service
Script:      /usr/local/bin/radio-switchd
User:        root
Restart:     always
```

**What it does:**
- Polls `http://127.0.0.1:8089/rtmp_stat` every 1 second
- Checks if `/hls/live/index.m3u8` exists and has fresh segments
- Checks RTMP client count for live application
- Writes current active source to `/run/radio/active`:
  - `live` — when live stream is detected
  - `autodj` — when no live stream (default)
- Updates `/var/www/radio/data/nowplaying.json` to "LIVE-SHOW" when live

### 2.3 radio-hls-relay.service
**Purpose:** Creates stable HLS output for seamless switching

```
Service:     radio-hls-relay.service
Script:      /usr/local/bin/radio-hls-relay (Python)
User:        root
Restart:     always
State File:  /var/lib/radio-hls-relay/state.json
```

**What it does:**
- Reads `/run/radio/active` to determine current source
- Reads segments from `/var/www/hls/autodj/` or `/var/www/hls/live/`
- Creates symlinks in `/var/www/hls/current/` with stable names (`seg-0.ts`, `seg-1.ts`, etc.)
- Generates `/var/www/hls/current/index.m3u8` with monotonic sequence numbers
- Inserts `#EXT-X-DISCONTINUITY` when switching sources
- This is what enables switching WITHOUT page refresh

### 2.4 nginx.service
**Purpose:** Web server and RTMP server

```
Service:     nginx.service
Config:      /etc/nginx/nginx.conf
RTMP Config: /etc/nginx/rtmp.conf
```

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

        # Live ingest (external encoders)
        application live {
            live on;
            on_publish http://127.0.0.1:8088/auth;  # Authentication
            hls on;
            hls_path /var/www/hls/live;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;
            exec_publish /usr/local/bin/hls-switch live;
            exec_publish_done /usr/local/bin/hls-switch autodj;
        }

        # AutoDJ output (localhost only)
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

### 3.2 RTMP Statistics Endpoint
**File:** `/etc/nginx/conf.d/rtmp_stat.conf`

```nginx
server {
    listen 127.0.0.1:8089;
    location /rtmp_stat {
        rtmp_stat all;
    }
}
```

### 3.3 RTMP Authentication
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

### 3.4 Radio Website Virtual Host
**File:** `/etc/nginx/sites-available/radio.peoplewelike.club.conf`

```nginx
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club;
    root /var/www/radio.peoplewelike.club;
    index index.html;

    location /hls {
        alias /var/www/hls;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "no-cache";
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    location /api/nowplaying {
        alias /var/www/radio/data/nowplaying.json;
        add_header Content-Type application/json;
        add_header Cache-Control "no-cache";
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

*(SSL is managed by Certbot — redirects HTTP to HTTPS)*

---

## 4. Directory Structure

```
/var/www/
├── hls/                              # HLS output (nginx-rtmp writes here)
│   ├── autodj/                       # AutoDJ HLS segments
│   │   ├── index.m3u8
│   │   └── index-*.ts
│   ├── live/                         # Live stream HLS segments
│   │   ├── index.m3u8
│   │   └── index-*.ts
│   └── current/                      # Stable relay output (served to players)
│       ├── index.m3u8
│       └── seg-*.ts → symlinks
├── radio/
│   └── data/
│       └── nowplaying.json           # Current track metadata
└── radio.peoplewelike.club/          # Web player files
    └── index.html

/var/lib/radio/
├── music/                            # Music library
│   ├── default/                      # Default/fallback music
│   │   └── *.mp3
│   ├── monday/
│   │   ├── morning/                  # 06:00-12:00
│   │   ├── day/                      # 12:00-18:00
│   │   └── night/                    # 18:00-06:00
│   ├── tuesday/                      # ... same structure
│   └── ...                           # ... for all weekdays
└── loops/                            # Video loops
    └── *.mp4                         # 1920x1080, 30fps, H.264

/run/radio/
└── active                            # Current source: "live" or "autodj"

/var/lib/radio-hls-relay/
└── state.json                        # HLS relay state persistence

/etc/radio/
└── credentials                       # Stream credentials (backup reference)

/usr/local/bin/
├── autodj-stream                     # AutoDJ ffmpeg script
├── radio-switchd                     # Switch detection daemon
├── radio-hls-relay                   # HLS relay daemon (Python)
├── hls-switch                        # Legacy switch hook
└── radio-ctl                         # Management utility
```

---

## 5. Stream Credentials

| Setting | Value |
|---------|-------|
| **RTMP Server** | `rtmp://ingest.peoplewelike.club:1935/live` |
| **Stream Key** | `likewe` |
| **Password** | *(none)* |
| **Full URL** | `rtmp://ingest.peoplewelike.club:1935/live/likewe` |

### Encoder Setup (Blackmagic/OBS)

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
| **AutoDJ HLS** (internal) | /hls/autodj/index.m3u8 |
| **Live HLS** (internal) | /hls/live/index.m3u8 |
| **RTMP Stats** (internal) | http://127.0.0.1:8089/rtmp_stat |

---

## 7. Management Commands

### radio-ctl utility

```bash
radio-ctl start    # Start all radio services
radio-ctl stop     # Stop all radio services
radio-ctl restart  # Restart all radio services
radio-ctl status   # Show service status + active source
radio-ctl logs     # Follow live logs from all services
```

### Individual service management

```bash
# AutoDJ
systemctl start|stop|restart|status autodj-stream
journalctl -u autodj-stream -f

# Switch daemon
systemctl start|stop|restart|status radio-switchd
journalctl -u radio-switchd -f

# HLS relay
systemctl start|stop|restart|status radio-hls-relay
journalctl -u radio-hls-relay -f

# Nginx
systemctl reload nginx
nginx -t  # Test config
```

---

## 8. How Switching Works

### Automatic Detection Flow

1. **Live encoder starts streaming** to `rtmp://ingest.../live/likewe`
2. **nginx-rtmp** authenticates via `/auth` endpoint, accepts stream
3. **nginx-rtmp** starts writing HLS segments to `/var/www/hls/live/`
4. **nginx-rtmp** calls `exec_publish` hook → `/usr/local/bin/hls-switch live`
5. **radio-switchd** detects:
   - Live HLS playlist exists
   - Has valid segments
   - RTMP nclients > 0 OR playlist mtime < 8 seconds
6. **radio-switchd** writes `live` to `/run/radio/active`
7. **radio-hls-relay** reads `active`, starts using `/hls/live/` as source
8. **radio-hls-relay** inserts `#EXT-X-DISCONTINUITY` in playlist
9. **Player** receives new segments seamlessly (no refresh needed)

### When Live Stops

1. **Encoder disconnects**
2. **nginx-rtmp** calls `exec_publish_done` → `/usr/local/bin/hls-switch autodj`
3. **radio-switchd** detects live is no longer healthy
4. **radio-switchd** writes `autodj` to `/run/radio/active`
5. **radio-hls-relay** switches back to `/hls/autodj/` source
6. **Player** continues seamlessly

---

## 9. Media Upload Locations

### Music Files (.mp3)

```bash
# Default (always plays if scheduled folder empty)
/var/lib/radio/music/default/

# Scheduled by day and time
/var/lib/radio/music/monday/morning/    # 06:00-12:00
/var/lib/radio/music/monday/day/        # 12:00-18:00
/var/lib/radio/music/monday/night/      # 18:00-06:00
# ... same for all weekdays
```

**Note:** Current autodj-stream uses `/default/` folder only. To enable scheduled playback, modify `/usr/local/bin/autodj-stream` to check day/time and select appropriate folder.

### Video Loops (.mp4)

```bash
/var/lib/radio/loops/
```

**Requirements:**
- Resolution: 1920x1080
- Frame rate: 30fps
- Codec: H.264
- Multiple files = random rotation

### Setting Permissions After Upload

```bash
chown -R root:audio /var/lib/radio/music/
chown -R root:audio /var/lib/radio/loops/
chmod -R 775 /var/lib/radio/music/
chmod -R 775 /var/lib/radio/loops/
```

---

## 10. Now Playing Metadata

### File Location
`/var/www/radio/data/nowplaying.json`

### AutoDJ Format
```json
{
  "title": "Track Title",
  "artist": "Artist Name",
  "mode": "autodj"
}
```

### Live Format
```json
{
  "title": "LIVE-SHOW",
  "artist": "Live Broadcast",
  "mode": "live"
}
```

### API Endpoint
```
GET https://radio.peoplewelike.club/api/nowplaying
```

---

## 11. Troubleshooting

### Check service status
```bash
radio-ctl status
```

### Check current active source
```bash
cat /run/radio/active
```

### Check HLS segments
```bash
ls -la /var/www/hls/autodj/
ls -la /var/www/hls/live/
ls -la /var/www/hls/current/
```

### Check RTMP connections
```bash
curl -s http://127.0.0.1:8089/rtmp_stat | grep -A5 '<application>'
```

### Test local RTMP publish
```bash
timeout 10 ffmpeg -re -f lavfi -i testsrc -f lavfi -i sine \
  -c:v libx264 -c:a aac -f flv rtmp://127.0.0.1:1935/live/likewe
```

### Common Issues

| Issue | Solution |
|-------|----------|
| No HLS segments | Check autodj-stream logs: `journalctl -u autodj-stream` |
| Live not detected | Check switchd logs: `journalctl -u radio-switchd` |
| Player stuck loading | Restart relay: `systemctl restart radio-hls-relay` |
| 404 on stream | Check nginx: `nginx -t && systemctl reload nginx` |
| Encoder "cache collecting" | Check firewall: `ufw allow 1935/tcp` |

---

## 12. Security Notes

- **Port 1935** is open for RTMP ingest
- **Stream key** `likewe` provides basic authentication
- **RTMP stats** endpoint is internal only (127.0.0.1:8089)
- **SSL** via Let's Encrypt (auto-renewal via certbot.timer)
- **CORS** headers allow any origin (for embedded players)

### Firewall Rules
```bash
ufw status
# Should show:
# 22/tcp    ALLOW   (SSH)
# 80/tcp    ALLOW   (HTTP)
# 443/tcp   ALLOW   (HTTPS)
# 1935/tcp  ALLOW   (RTMP)
```

---

## 13. Backup Paths

Before making changes, backup:

```bash
/etc/nginx/rtmp.conf
/etc/nginx/conf.d/rtmp_stat.conf
/etc/nginx/conf.d/rtmp_auth.conf
/etc/nginx/sites-available/radio.peoplewelike.club.conf
/usr/local/bin/autodj-stream
/usr/local/bin/radio-switchd
/usr/local/bin/radio-hls-relay
/etc/systemd/system/autodj-stream.service
/etc/systemd/system/radio-switchd.service
/etc/systemd/system/radio-hls-relay.service
/var/www/radio.peoplewelike.club/index.html
```

---

## 14. Coexistence with av.peoplewelike.club

**DO NOT MODIFY these paths** (Illuminatics Pitch site):

```
/var/www/av.peoplewelike.club/
/opt/avpitch/
/etc/nginx/sites-available/av.peoplewelike.club.conf
/usr/local/bin/avpitch-update
```

The radio system is completely isolated and does not share any resources with the pitch site.

---

## 15. Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────┐
│                    QUICK REFERENCE                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  MANAGEMENT                                                      │
│    radio-ctl status         Check all services                  │
│    radio-ctl restart        Restart all services                │
│    radio-ctl logs           View live logs                      │
│                                                                  │
│  STREAM KEY                                                      │
│    Key: likewe                                                   │
│    Server: rtmp://ingest.peoplewelike.club:1935/live            │
│                                                                  │
│  UPLOAD LOCATIONS                                                │
│    Music: /var/lib/radio/music/default/                         │
│    Loops: /var/lib/radio/loops/                                 │
│                                                                  │
│  URLS                                                            │
│    Player: https://radio.peoplewelike.club/                     │
│    HLS: https://radio.peoplewelike.club/hls/current/index.m3u8  │
│                                                                  │
│  ACTIVE SOURCE                                                   │
│    cat /run/radio/active                                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

*Document generated: January 2026*
*Server: srv1178155 (72.60.181.89)*
