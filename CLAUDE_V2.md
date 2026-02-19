# claude_v2.md — People We Like Radio v2 (Docker Cutover, Zurich Scheduling, Seamless Switch)

You are Claude Code operating in `gedzilius-lang/radijas`. Act as the owning engineer for the radio service.
You will read this file first, then execute the plan end-to-end.

## Session Rules

1) Immediately run `/compact` and keep responses minimal and execution-focused.
2) Maintain a Git-tracked log of everything you do:
   - Create `ops/logs/SESSION-YYYYMMDD-HHMMZ.md`
   - Every VPS action must be recorded: command intent, files changed, service restarts, test outputs (short).
3) All changes must be committed to GitHub in small commits with clear messages.
4) No broad repo scans. Only read files you need, at most 8 at a time.
5) Hard cutover is requested: v1 systemd services will be stopped and disabled after v2 passes verification.

## Target Outcome (v2 Requirements)

### Public contract (must keep working)
- Player: `https://radio.peoplewelike.club/`
- Stable HLS: `https://radio.peoplewelike.club/hls/current/index.m3u8` (never changes)
- Status API (v2): `https://radio.peoplewelike.club/api/status` (JSON)
- Nowplaying API (keep compatibility): `https://radio.peoplewelike.club/api/nowplaying` (JSON)

### Operational behavior
- AutoDJ runs 24/7 and never stops (unless container crash; it must auto-restart).
- Live ingest switches automatically to LIVE within <= 10 seconds when a publisher is present.
- When live stops, switches back to AutoDJ within <= 10 seconds.
- Switching must be seamless without player refresh. This requires the relay playlist strategy.

### Scheduling (Zurich time)
AutoDJ music selection is driven by Zurich local time (Europe/Zurich):
- Morning: 07:00–12:00
- Day: 12:00–17:00
- Evening: 17:00–22:00
- Night: 22:00–07:00

Folder structure under the existing music root (do not relocate existing roots; add folders inside):
- `/var/lib/radio/music/allmusic/`
- `/var/lib/radio/music/monday/{morning,day,evening,night}/`
- ...
- `/var/lib/radio/music/sunday/{morning,day,evening,night}/`

If the scheduled folder is empty/unusable -> fallback to `/allmusic`.
MP3 only for now.

### Video overlay
- MP4 loop files exist under `/var/lib/radio/loops/` (silent mp4).
- AutoDJ output is a single A/V stream (video loop + audio from playlist) delivered as HLS to all listeners (broadcast model; not per-user transcoding).
- CPU minimization is required. Prefer stream-copy/remux where possible; otherwise use a conservative encode profile.

### RTMP ingest contract (DJ instruction)
Required DJ publish URL:
`rtmp://radio.peoplewelike.club/club/live/people`

Implementation detail:
nginx-rtmp normally expects `rtmp://host/<app>/<stream>`. The stream name may not accept `/`.
You MUST test publish. If slash is not accepted, implement a compatibility method that still gives DJs a single copy/paste OBS URL that functions. Do not guess.

## Proven v1 Components to Reuse (as logic, not as systemd)

The current server already implemented the correct “no-refresh switch” solution:
- Switch daemon that decides LIVE vs AUTODJ (based on RTMP stats and/or playlist freshness).
- Relay daemon that generates a stable playlist with monotonic segment names:
  `/var/www/hls/current/index.m3u8` referencing `seg-<seq>.ts` and inserting `#EXT-X-DISCONTINUITY` on source changes.

This architecture is described in handover docs and must be retained as core logic.

## Current VPS Facts (from provided scan; treat as authoritative)

- OS: Ubuntu 22.04
- Timezone currently: UTC (DO NOT change host timezone unless explicitly required; run scheduler in container TZ=Europe/Zurich)
- nginx currently binds :80 :443 :1935; RTMP stat is on 127.0.0.1:8089; auth server on 127.0.0.1:8088
- Paths:
  - HLS root: `/var/www/hls/{autodj,live,current,placeholder}`
  - Web root: `/var/www/radio.peoplewelike.club/`
  - Data: `/var/www/radio/data/nowplaying.json`
  - Music: `/var/lib/radio/music`
  - Loops: `/var/lib/radio/loops`
- v1 systemd services exist:
  `liquidsoap-autodj`, `autodj-video-overlay`, `radio-switchd`, `radio-hls-relay`, `radio-nowplayingd`

## Cutover Strategy (hard cutover with safety bundle)

### Phase 0 — Start log + backup bundle (mandatory)
1) Create the session log file: `ops/logs/SESSION-YYYYMMDD-HHMMZ.md`.
2) Create a VPS backup bundle BEFORE changes, and record its path in the session log. Use the proven bundle approach:
   - tar up `/etc/nginx/rtmp.conf`, `/etc/nginx/conf.d/rtmp_stat.conf`, `/etc/nginx/conf.d/rtmp_auth.conf`,
     `/etc/nginx/sites-available/radio.peoplewelike.club.conf`, `/usr/local/bin/*radio*`, `/usr/local/bin/autodj*`,
     `/etc/systemd/system/*radio*`, `/etc/systemd/system/*autodj*`, `/etc/liquidsoap`, and relay state.
3) Commit a new `ops/runbooks/backup.md` describing the exact backup command and restore steps.

### Phase 1 — Repo work: add Docker v2 stack
Implement inside this repository:

#### Files to add
- `docker-compose.yml`
- `docker/rtmp/nginx.conf` (nginx-rtmp config)
- `docker/web/nginx.conf` (HTTP server config, likely only on localhost)
- `docker/web/www/index.html` (video.js player, plays `/hls/current/index.m3u8`)
- `docker/switch/radio-switchd` (ported; use robust live detection)
- `docker/switch/radio-hls-relay.py` (ported from v1; output to `/var/www/hls/current`)
- `docker/autodj/`:
  - `scheduler.py` (Zurich time folder selection + fallback)
  - `liquidsoap.liq` OR a simpler mp3 streaming mechanism (choose what guarantees working)
  - `overlay.sh` (ffmpeg loop video + audio feed -> RTMP autodj/index)
- `scripts/v2_install_docker.sh`
- `scripts/v2_deploy.sh`
- `scripts/v2_verify.sh`
- `docs/DJ_INGEST.md` (OBS + Blackmagic settings, publish URL, troubleshooting)
- `docs/OPERATIONS.md` (how to start/stop, where logs are, how to debug)

#### API output files
- Keep generating `/var/www/radio/data/nowplaying.json` for `/api/nowplaying`.
- Add `/var/www/radio/data/status.json` for `/api/status`.

### Phase 2 — VPS prep: install Docker and stage v2 without conflicting ports
Constraints:
- Host nginx must keep :80/:443 (TLS termination stays on host).
- RTMP port :1935 must ultimately be served by the v2 RTMP container.
Because v1 already holds :1935, you must stage v2 RTMP on an alternate port first (e.g. 1936) for validation, then cutover.

Required staging approach:
1) Install docker + compose plugin.
2) Start v2 with RTMP port mapped to `1936:1935` initially.
3) Configure v2 HLS directories to use separate staging roots:
   - `/var/www/hls_v2/{autodj,live,current}` during staging, OR
   - reuse existing `/var/www/hls/...` only after v1 is stopped.
Staging must avoid touching production `/var/www/hls/current` until cutover.

### Phase 3 — Verification gates (must pass before cutover)

#### Gate A: AutoDJ produces stable HLS in staging
- Confirm v2 autodj HLS playlist exists and is updating.
- Confirm the relay playlist exists and references monotonic seg names.
- Confirm the player can load the staging stream (use a temporary local URL or direct file access).

#### Gate B: Live ingest switching in staging
- Publish a test live stream to staging RTMP port.
- Confirm within 10 seconds:
  - active mode changes to `live`
  - relay inserts discontinuity
  - playback continues without refresh

#### Gate C: CPU sanity check
- Record `top` snapshot and `docker stats` snapshot in session log.
- If CPU is excessive, downgrade output (720p, lower bitrate, copy video if safe).

### Phase 4 — Hard Cutover (stop v1, replace ports/paths)

1) Stop and disable v1 systemd services:
   - `liquidsoap-autodj`
   - `autodj-video-overlay`
   - `radio-switchd`
   - `radio-hls-relay`
   - `radio-nowplayingd`
2) Stop any v1 nginx-rtmp usage of :1935 (nginx currently owns it).
3) Update v2 docker compose:
   - RTMP maps `1935:1935`
   - HLS roots switch from staging to production:
     `/var/www/hls/{autodj,live,current}`
4) Restart v2 stack and verify:
   - `curl -fsS https://radio.peoplewelike.club/hls/current/index.m3u8 | head`
   - `curl -fsS https://radio.peoplewelike.club/api/status`
   - Player loads and plays.

### Phase 5 — Update host nginx vhost only as necessary
Prefer: keep host nginx serving `/var/www/radio.peoplewelike.club` as-is, just update the index.html if needed.
Host nginx must serve:
- `/hls` -> alias `/var/www/hls` with no-cache and CORS headers
- `/api/nowplaying` -> alias to nowplaying.json
- `/api/status` -> alias to status.json

Do not modify unrelated sites (e.g. av.peoplewelike.club).

## Implementation Details (choose “guarantees working”)

### Live detection logic (required)
Use BOTH:
- RTMP stats `<nclients>` for the live application (from a local endpoint), AND/OR
- live playlist freshness (mtime <= 10s and contains `.ts`)

The goal is to avoid false “live” mode from stale playlists.

### Relay algorithm (required)
- Always generate a stable playlist in `/var/www/hls/current/index.m3u8`
- Always reference segments as `seg-<monotonic>.ts`
- Insert `#EXT-X-DISCONTINUITY` on source change
- Keep a fixed window (10–12 segments)
- Prefer symlink to source segment; if symlink fails, copy.

### Scheduling algorithm (required)
At runtime (every track boundary):
1) Determine Zurich local time day-of-week + daypart.
2) Pick a random MP3 from that folder.
3) If folder empty -> fallback to `/music/allmusic`.
4) Update nowplaying.json.

### ffmpeg overlay profile (CPU minimization)
Start with the conservative “works everywhere” profile:
- 720p, 30fps, keyframe every 6s (GOP=180), repeat headers, yuv420p.
If loop mp4s are already compatible, attempt:
- `-c:v copy` and re-encode only audio, but only if HLS playback remains stable and segment boundaries are correct.

Record final ffmpeg command in docs.

## Token discipline + reporting
- Use `/compact` always.
- Log every VPS command in `ops/logs/SESSION-...md`.
- For each commit, include a short “why” and “verification result”.
- If any gate fails, stop and write:
  - observed symptom
  - logs to check
  - minimal next experiment

## Deliverables Checklist (must exist in repo)
- [ ] docker-compose.yml and docker/* configs
- [ ] scripts/v2_install_docker.sh
- [ ] scripts/v2_deploy.sh
- [ ] scripts/v2_verify.sh
- [ ] docs/DJ_INGEST.md
- [ ] docs/OPERATIONS.md
- [ ] ops/logs/SESSION-...md (for the work session)
- [ ] ops/runbooks/backup.md
- [ ] Updated web player (video.js) showing:
      - “Now in Zürich” time
      - “Your local time” (browser-based)
      - current mode (LIVE/AUTODJ) via /api/status

## Verification Commands (final production)
These must pass after cutover:

```bash
# HLS is live
curl -fsS "https://radio.peoplewelike.club/hls/current/index.m3u8?ts=$(date +%s)" | head -n 30

# Source playlists exist
curl -fsS "https://radio.peoplewelike.club/hls/autodj/index.m3u8?ts=$(date +%s)" | head -n 10
curl -fsS "https://radio.peoplewelike.club/hls/live/index.m3u8?ts=$(date +%s)" | head -n 10 || true

# APIs
curl -fsS https://radio.peoplewelike.club/api/nowplaying
curl -fsS https://radio.peoplewelike.club/api/status

# Active mode file (if exposed on host mount)
cat /run/radio/active || true

# Docker health
docker ps
docker logs --tail=200 pwl-radio-switch || true
