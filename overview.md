# People We Like Radio — Overview

## What Was Implemented

Three production features were added to the Video.js HLS radio player:

### 1. Remaining Song Countdown
- MM:SS countdown in the now-playing metadata bar, ticking every second.
- Computed from `duration` and `started_at` fields returned by `/api/nowplaying`.
- Resyncs on every 3-second metadata poll and on `visibilitychange` (tab wake).
- Shows `--:--` when data is missing; hides completely in live mode via CSS `:empty`.

### 2. Active Unique Listener Counter
- Server-truth count displayed below the player card.
- Each browser gets a stable `session_id` stored in `localStorage` (`radio_sid` key).
- While the player is playing, a heartbeat POST fires every 25 seconds.
- The Python API server (`radio_api.py`) keeps an in-memory dict with a 90-second TTL; expired entries are pruned on each request.
- Multiple tabs in the same browser share the same session ID, so the count stays accurate.

### 3. Share to Instagram Story / Clipboard
- "Share" button below the player, next to the listener counter.
- On click: POST `/api/share/snapshot` → server saves current track metadata as a JSON snapshot.
- Server renders `/share/<id>` with full OG meta tags (og:title, og:image, og:url, twitter:card) and a meta-refresh redirect to the radio homepage.
- OG image (`/og/<id>.png`, 1200×630) generated from an SVG template using `rsvg-convert`, `convert`, or `ffmpeg` (fallback chain — no Python image libraries required).
- On mobile: Web Share API (native share sheet). On desktop: copies the share URL to clipboard.

---

## Architecture

```
OBS (RTMP) → nginx-rtmp → Liquidsoap (autodj + live input)
                ↓
          FFmpeg overlay → nginx-rtmp → HLS segments
                                          ↓
                            radio-hls-relay → /hls/current/index.m3u8
                                                    ↓
                            Video.js 8.10 player (Vite frontend on Hostinger)

Python API server (radio_api.py) on 127.0.0.1:3000
  └─ proxied by nginx at /api/listeners/*, /api/share/*, /share/*, /og/*
```

- **VPS** (`stream.peoplewelike.club`): nginx-rtmp, Liquidsoap, FFmpeg, HLS relay, API server, all managed by systemd.
- **Hostinger** (`radio.peoplewelike.club`): static Vite build served via GitHub Pages or Hostinger file manager. `VITE_BACKEND_URL` points at the VPS.

---

## Files Changed / Added

| File | Status | Purpose |
|------|--------|---------|
| `index.html` | Modified | Added countdown div, listener counter, share button |
| `src/main.js` | Modified | Countdown logic, heartbeat, listener count, share handler |
| `src/style.css` | Modified | Countdown, below-card, listeners, share-btn styles |
| `vite.config.js` | Modified | Added `/share` and `/og` dev proxies |
| `server/radio_api.py` | **New** | Python API server (listeners, snapshots, OG images) |
| `install/04-configure-liquidsoap.sh` | Modified | `duration` + `started_at` in nowplaying JSON |
| `install/05-create-scripts.sh` | Modified | Live mode nowplaying includes duration/started_at |
| `install/11-videojs-player-dj-input.sh` | Modified | VPS inline player updated with all 3 features |
| `install/14-install-api-server.sh` | **New** | Deploys API server, systemd unit, nginx proxy rules |
| `install/15-backup-to-github.sh` | **New** | Git backup/push script |

---

## Configuration / Environment Variables

### Vite Frontend (`.env`)
| Variable | Example | Description |
|----------|---------|-------------|
| `VITE_BACKEND_URL` | `https://stream.peoplewelike.club` | VPS backend URL for API and HLS |

### API Server (systemd environment)
| Variable | Default | Description |
|----------|---------|-------------|
| `RADIO_API_PORT` | `3000` | Port for the Python API server |
| `RADIO_BASE_URL` | `https://radio.peoplewelike.club` | Public URL used in share links and OG tags |
| `RADIO_DATA_DIR` | `/var/www/radio/data` | Directory for snapshots and OG image cache |

---

## How to Test Each Feature

### Countdown
1. Play the stream in autodj mode.
2. Observe MM:SS counting down in the now-playing bar (right side).
3. Switch tabs and return — countdown should resync.
4. In live mode, countdown should disappear.

### Listener Counter
1. Open the player and press play — count should increment within 15 seconds.
2. Open a second tab — count should stay at 1 (same session).
3. Open in a different browser or incognito — count should go to 2.
4. Pause in one browser — after ~90 seconds, count should drop.

### Share Button
1. Click "Share" — label should change to "Copied" for 2 seconds.
2. Paste — should be a URL like `https://radio.peoplewelike.club/share/<id>`.
3. Open that URL — should show OG meta tags (test with `curl -s <url> | grep og:`).
4. Open `https://stream.peoplewelike.club/og/<id>.png` — should be a 1200×630 PNG.
5. On mobile: native share sheet should appear.

---

## Known Limitations / Fallback Behavior

- **Countdown accuracy**: Depends on `started_at` being set when the track starts. If Liquidsoap restarts mid-track, the timestamp resets and the countdown may be slightly off until the next track.
- **Listener count is in-memory**: Restarting `radio-api` resets the count to 0. Listeners re-register within 25 seconds via heartbeat.
- **OG image generation**: Requires at least one of `rsvg-convert`, `convert` (ImageMagick), or `ffmpeg`. If none are available, the `/og/<id>.png` endpoint returns a 500 error but share links still work (just without a preview image).
- **Share snapshots are file-based**: Stored in `/var/www/radio/data/snapshots/`. No automatic cleanup — over time these accumulate (each is ~200 bytes of JSON).
- **No HTTPS on the API server itself**: It binds to 127.0.0.1; nginx handles TLS termination.

---

## How to Deploy

### VPS (stream server)
```bash
# Run install scripts in order (as root):
bash install/04-configure-liquidsoap.sh   # updated nowplaying with duration/started_at
bash install/05-create-scripts.sh          # updated live nowplaying
bash install/11-videojs-player-dj-input.sh # updated inline player
bash install/14-install-api-server.sh      # new API server + nginx proxy

# Verify:
systemctl status radio-api
curl -s http://127.0.0.1:3000/api/listeners/count
```

### Hostinger (frontend)
```bash
# Build:
npm install
npm run build
# Upload contents of dist/ to Hostinger public_html/

# Or connect GitHub repo to Hostinger for auto-deploy from main branch.
```

### GitHub Backup
```bash
bash install/15-backup-to-github.sh
```
