# People We Like Radio - VPS Installation

Complete installation scripts for deploying a 24/7 radio station with AutoDJ and live streaming capabilities.

## Quick Start

SSH to your VPS as root and run:

```bash
# Upload the install folder to your VPS, then:
cd /path/to/install
chmod +x *.sh
./deploy-all.sh
```

Or run each step manually:

```bash
./00-preflight.sh          # System checks
./01-install-dependencies.sh  # Install packages
./02-create-directories.sh    # Create folder structure
./03-configure-nginx.sh       # Configure nginx + RTMP
./04-configure-liquidsoap.sh  # Configure AutoDJ
./05-create-scripts.sh        # Create utility scripts
./06-create-services.sh       # Create systemd services
./07-setup-ssl.sh             # Get SSL certificates
./08-create-player.sh         # Create web player
./09-finalize.sh              # Start everything
./10-upgrade-player.sh        # Enhanced dark purple player (optional)
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     NGINX (ports 80/443)                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
│  │radio.pwl.club   │  │stream.pwl.club  │  │ingest.pwl.. │  │
│  └────────┬────────┘  └────────┬────────┘  └──────┬──────┘  │
└───────────┼─────────────────────┼─────────────────┼─────────┘
            │                     │                 │
            ▼                     ▼                 ▼
     ┌──────────────┐      ┌───────────┐    ┌────────────────┐
     │  Web Player  │      │ /hls/     │    │ RTMP :1935     │
     │  Video.js    │      │ current/  │    │ /live app      │
     └──────────────┘      └─────┬─────┘    └───────┬────────┘
                                 │                  │
                    ┌────────────┴────────────┐     │
                    │   radio-hls-relay       │     │
                    │   (seamless switching)   │     │
                    └────────────┬────────────┘     │
                                 │                  │
              ┌──────────────────┼──────────────────┤
              ▼                  ▼                  ▼
     ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐
     │ /hls/autodj/    │  │ /hls/live/      │  │ Live ingest │
     │ (HLS segments)  │  │ (HLS segments)  │  │ (Blackmagic)│
     └────────┬────────┘  └─────────────────┘  └─────────────┘
              │
     ┌────────┴────────┐
     │ autodj-video-   │
     │ overlay (ffmpeg)│
     └────────┬────────┘
              │
     ┌────────┴────────┐
     │ liquidsoap      │
     │ (scheduled      │
     │  playlists)     │
     └─────────────────┘
```

## Upload Locations

### Music Files (.mp3)

Upload to schedule-based folders:

```
/var/lib/radio/music/
├── monday/
│   ├── morning/   # 06:00 - 12:00
│   ├── day/       # 12:00 - 18:00
│   └── night/     # 18:00 - 06:00
├── tuesday/
│   ├── morning/
│   ├── day/
│   └── night/
├── wednesday/
│   └── ...
├── thursday/
│   └── ...
├── friday/
│   └── ...
├── saturday/
│   └── ...
├── sunday/
│   └── ...
└── default/       # Fallback when scheduled folder is empty
```

Files are shuffled within each folder. The system automatically switches based on the server's clock.

### Video Loops (.mp4)

Upload to:
```
/var/lib/radio/loops/
```

Requirements:
- Resolution: 1920x1080
- Frame rate: 30fps
- Codec: H.264
- Multiple files = random rotation

## Live Streaming

### Credentials (default)

| Setting | Value |
|---------|-------|
| RTMP Server | `rtmp://ingest.peoplewelike.club:1935/live` |
| Stream Key | `pwl-live-2024` |
| Password | `R4d10L1v3Str34m!` |
| Full URL | `rtmp://ingest.peoplewelike.club:1935/live/pwl-live-2024?pwd=R4d10L1v3Str34m!` |

### Blackmagic Web Presenter Setup

1. Platform: **Custom RTMP**
2. Server: `rtmp://ingest.peoplewelike.club:1935/live`
3. Stream Key: `pwl-live-2024?pwd=R4d10L1v3Str34m!`

### OBS Studio Setup

1. Settings → Stream
2. Service: Custom
3. Server: `rtmp://ingest.peoplewelike.club:1935/live`
4. Stream Key: `pwl-live-2024?pwd=R4d10L1v3Str34m!`

## Enhanced Player (Optional)

After initial installation, you can upgrade to the enhanced dark purple player:

```bash
./10-upgrade-player.sh
```

Features:
- Dark purple theme with floating particle animations
- AutoDJ/LIVE indicator with red glow when live
- Video toggle button for audio-only mode
- Chat sidebar with auto-assigned nicknames
- Mobile responsive (slide-out chat on mobile)
- Listener count display

## URLs

| Purpose | URL |
|---------|-----|
| Web Player | https://radio.peoplewelike.club/ |
| HLS Stream | https://radio.peoplewelike.club/hls/current/index.m3u8 |
| Now Playing API | https://radio.peoplewelike.club/api/nowplaying |

## Management Commands

```bash
radio-ctl start    # Start all services
radio-ctl stop     # Stop all services
radio-ctl restart  # Restart all services
radio-ctl status   # Show service status
radio-ctl logs     # Follow live logs
```

## Services

| Service | Description |
|---------|-------------|
| `liquidsoap-autodj` | Audio engine with scheduled playlists |
| `autodj-video-overlay` | FFmpeg combining video loop + audio |
| `radio-switchd` | Detects live input, triggers switch |
| `radio-hls-relay` | Generates stable HLS playlist |

## Changing Credentials

Edit `/etc/radio/credentials` and update `/etc/nginx/conf.d/rtmp_auth.conf`:

```bash
nano /etc/radio/credentials
nano /etc/nginx/conf.d/rtmp_auth.conf
nginx -t && systemctl reload nginx
```

## Troubleshooting

### Check service status
```bash
radio-ctl status
```

### View logs
```bash
radio-ctl logs
# Or individual service:
journalctl -u liquidsoap-autodj -f
```

### Test RTMP stats (live detection)
```bash
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -30
```

### Test HLS output
```bash
curl -fsS https://radio.peoplewelike.club/hls/current/index.m3u8 | head -20
```

### Check segments
```bash
ls -la /var/www/hls/autodj/
ls -la /var/www/hls/live/
ls -la /var/www/hls/current/
```

### Check active source
```bash
cat /run/radio/active
```

## Files Created

### Configuration
- `/etc/nginx/rtmp.conf` - RTMP server config
- `/etc/nginx/conf.d/rtmp_stat.conf` - Stats endpoint
- `/etc/nginx/conf.d/rtmp_auth.conf` - Authentication
- `/etc/nginx/sites-available/radio.peoplewelike.club.conf` - Web server
- `/etc/liquidsoap/radio.liq` - AutoDJ config
- `/etc/radio/credentials` - Stream credentials

### Scripts
- `/usr/local/bin/autodj-video-overlay` - Video overlay
- `/usr/local/bin/radio-switchd` - Switch daemon
- `/usr/local/bin/radio-hls-relay` - HLS relay
- `/usr/local/bin/hls-switch` - Legacy switch hook
- `/usr/local/bin/radio-ctl` - Control utility

### Systemd
- `/etc/systemd/system/liquidsoap-autodj.service`
- `/etc/systemd/system/autodj-video-overlay.service`
- `/etc/systemd/system/radio-switchd.service`
- `/etc/systemd/system/radio-hls-relay.service`

### Directories
- `/var/www/hls/` - HLS output
- `/var/lib/radio/music/` - Music library
- `/var/lib/radio/loops/` - Video loops
- `/var/www/radio.peoplewelike.club/` - Web player

## Does NOT Touch

These paths are preserved (av.peoplewelike.club):
- `/var/www/av.peoplewelike.club/`
- `/opt/avpitch/`
- `/etc/nginx/sites-available/av.peoplewelike.club.conf`
- `/usr/local/bin/avpitch-update`
