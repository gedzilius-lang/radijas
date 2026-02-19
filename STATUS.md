# People We Like Radio — System Status

**Server:** `72.60.181.89`  
**Project root:** `/opt/radijas-v2`  
**Last updated:** 2026-02-19  

---

## Overview

A self-hosted internet radio system running on a single VPS. It streams 24/7 via HLS with automatic DJ fallback, live RTMP ingest from OBS or any streaming software, and instant switching between AutoDJ and live stream with no listener interruption.

---

## Services

Five Docker containers managed by Docker Compose:

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `radio-rtmp` | `tiangolo/nginx-rtmp` | `1935` (RTMP) | Receives RTMP streams (autodj + live DJ), produces HLS segments |
| `radio-rtmp-auth` | custom Python | internal `8088` | Authenticates live DJ ingest via stream key |
| `radio-autodj` | custom FFmpeg | — | Continuously muxes music + loop video, pushes to RTMP |
| `radio-switch` | custom Python | — | Monitors live ingest, switches HLS source, writes status |
| `radio-web` | `nginx:alpine` | `8080` (HTTP) | Serves HLS playlist, web player, and status API |

---

## Feature Details

### 1. AutoDJ (`radio-autodj`)

- Runs 24/7 using `overlay.sh` — an infinite loop that picks one track at a time
- Selects MP3 tracks via `scheduler.py` using **time-of-day dayparts** (Zurich timezone):
  - `morning` 07:00–12:00, `day` 12:00–17:00, `evening` 17:00–22:00, `night` 22:00–07:00
- Folder priority per daypart: `weekday/daypart/` → `weekday/` → `allmusic/` → `default/` → any file
- Picks a **random MP4 loop video** from `/loops` per track
- Muxes audio + video with FFmpeg: `libx264 ultrafast`, 1280×720, 1500k CBR, 25fps, GOP=150 (aligns with 6s HLS fragments), AAC 128k stereo
- Writes `nowplaying` JSON to shared volume (title, duration, started_at)
- Pushes stream to internal RTMP: `rtmp://rtmp:1935/autodj/index`

### 2. RTMP Ingest (`radio-rtmp`)

- nginx-rtmp with two applications:
  - **`club`** — live DJ ingest from external sources, auth-protected
  - **`autodj`** — internal autodj publish (no auth required)
- Both produce 6-second HLS segments with 120s playlist window
- `hls_continuous on` prevents segment numbering resets on reconnect

### 3. Stream Key Auth (`radio-rtmp-auth`)

- Python HTTP server on port 8088
- nginx-rtmp `on_publish` sends POST body (`application/x-www-form-urlencoded`) — **not** query-string params
- Service reads POST body and validates the `name` field
- **Valid stream keys:** `people`, `pwl-live-2024`
- Returns HTTP 200 (allow) or 403 (reject)

> **Bug fixed:** Original nginx config used `$arg_name` (query-string only) which always returned 403, making live ingest permanently broken. Replaced with dedicated Python auth container.

### 4. Switch Daemon (`radio-switch` — `switchd.py`)

- Polls `http://rtmp:8089/rtmp_stat` every 1 second
- Counts active clients on the `club` application
- Writes `"live"` or `"autodj"` to `/run/radio/active`
- Triggers relay to switch HLS source

### 5. HLS Relay (`radio-switch` — `relay.py`)

- Reads `/run/radio/active` every 0.5 seconds
- Selects source HLS directory (`/var/www/hls/live` or `/var/www/hls/autodj`)
- **Finds the correct playlist:** prefers `index.m3u8`, falls back to any `*.m3u8` sorted by mtime (nginx-rtmp names the playlist after the stream key, e.g. `people.m3u8`)

> **Bug fixed:** Hardcoded `index.m3u8` meant relay never found the live playlist → `status.json` never updated to "live".

- Creates stable `current/` HLS playlist with **monotonic segment IDs** (`seg-NNN.ts` symlinks)
- Inserts `#EXT-X-DISCONTINUITY` tag on source switch — listeners hear continuous audio with a clean cut
- Keeps max 30 segments, cleans old symlinks (prevents inode exhaustion from v1)
- Writes `status.json`: `{ "source": "live"|"autodj", "seq": N, "updated": epoch }`

### 6. Web Player & API (`radio-web`)

- Serves the HLS stream at `/hls/current/index.m3u8`
- Correct MIME types: `application/x-mpegURL` for `.m3u8`, `video/MP2T` for `.ts`
- No-cache headers on `.m3u8` playlists (ensures player always fetches latest)
- CORS enabled for cross-origin player use
- REST endpoints:
  - `GET /api/status` → `status.json` (active source, segment sequence)
  - `GET /api/nowplaying` → `nowplaying` JSON (current track title, duration)
- Serves the frontend HTML player from `/docker/web/www/`

---

## Switch Timing (Verified 2026-02-19)

| Event | Time |
|-------|------|
| DJ connects live | Switch to live: **~7 seconds** |
| DJ disconnects | Return to autodj: **~1 second** |

Both pass the ≤10 second requirement. Switch time equals one HLS segment boundary (first complete segment from the live source).

---

## File & Directory Layout

```
/opt/radijas-v2/              ← git repo root
├── docker-compose.yml
├── docker/
│   ├── autodj/
│   │   ├── Dockerfile
│   │   ├── overlay.sh        ← FFmpeg loop + track picker
│   │   └── scheduler.py      ← Daypart-aware track selector
│   ├── rtmp/
│   │   └── nginx.conf        ← nginx-rtmp: club + autodj apps
│   ├── rtmp-auth/
│   │   ├── Dockerfile
│   │   └── auth.py           ← POST body stream key validator
│   ├── switch/
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh     ← Starts switchd + relay in parallel
│   │   ├── switchd.py        ← RTMP stat poller
│   │   └── relay.py          ← HLS re-sequencer
│   └── web/
│       ├── nginx.conf        ← HTTP: HLS + API + player
│       └── www/
│           └── index.html    ← Web player frontend
├── install/                  ← VPS provisioning scripts (00–10)
└── STATUS.md                 ← this file
```

**Host bind-mount paths:**

| Purpose | Path on host |
|---------|-------------|
| MP3 music tracks | `/var/lib/radio/music/` |
| MP4 loop videos | `/var/lib/radio/loops/` |
| HLS output | `/var/www/hls/` |
| Status / nowplaying | `/var/www/radio/data/` |

**Music folder structure:**
```
/var/lib/radio/music/
├── allmusic/       ← plays any time (fallback)
├── default/        ← last-resort fallback
├── monday/
│   ├── morning/    ← plays Mon 07–12
│   ├── day/        ← plays Mon 12–17
│   ├── evening/    ← plays Mon 17–22
│   └── night/      ← plays Mon 22–07
├── friday/
└── saturday/
```

---

## Live RTMP Ingest (DJ Input)

| Setting | Value |
|---------|-------|
| RTMP server | `rtmp://radio.peoplewelike.club/club/live` |
| Stream key | `people` |
| Alt stream key | `pwl-live-2024` |

Use with OBS, BUTT, or any RTMP-capable software. Set keyframe interval to 1–2 seconds for fastest switching.

---

## Current Stack State

All 5 containers running as of 2026-02-19:

```
radio-rtmp       Up (healthy)   — port 1935
radio-rtmp-auth  Up             — internal port 8088
radio-autodj     Up ~10h        — streaming continuously
radio-switch     Up ~1h         — monitoring + relaying
radio-web        Up ~10h        — port 8080
```

---

## Bugs Fixed in This Session (2026-02-19)

| # | Bug | Root Cause | Fix |
|---|-----|-----------|-----|
| 1 | Live ingest always rejected (403) | nginx `$arg_name` reads query-string; nginx-rtmp sends POST body — they never match | New `rtmp-auth` Python service reads POST body with `parse_qs()` |
| 2 | `status.json` never updated to "live" | `relay.py` hardcoded `index.m3u8`; nginx-rtmp names playlist after stream key (`people.m3u8`) | Added `find_m3u8()` fallback glob in `relay.py` |
