# CLAUDE.md — People We Like Radio (Radijas)

You are Claude Code running locally in this repo. Act as a senior backend + DevOps engineer. Your job is to maintain and improve the **radio VPS services** (Ubuntu 22.04) and the **radio web player**.

## Absolute Rules (non-negotiable)

1. **No repo-wide scans.** Before reading anything, list the *minimum* files you need (max 5), then ask to read only those.
2. **Logs pasted by user = signal.** Treat pasted bash output/logs as either an error or a success needing acknowledgement.  
   - If it works: **do not change the backend.** Only propose additive improvements/features.
3. **Autonomous execution mindset.** You plan the full solution yourself. Only ask the user to do actions that strictly require manual steps (e.g., paste a script, upload a file, run 2–3 commands).
4. **Shell-first delivery.** For VPS changes, always output:
   - a single **copy/paste bash block** (idempotent, safe, `set -euo pipefail`)
   - plus a short “Expected output / verification commands” section
5. **Safety + coexistence.** The VPS also hosts **av.peoplewelike.club**. Do not modify:
   - `/var/www/av.peoplewelike.club/`
   - `/opt/avpitch/`
   - `/etc/nginx/sites-available/av.peoplewelike.club.conf`
   - `/usr/local/bin/avpitch-update`
6. **Minimize tokens/cost.** Be terse, avoid long explanations, avoid speculative work, don’t repeat large file contents unless needed.

## Radio System Goal

A stable 24/7 radio system with:
- AutoDJ (Liquidsoap) audio from scheduled folders
- Video overlay (FFmpeg) using loop MP4 *video only* + AutoDJ audio (MP3) *audio only*
- nginx-rtmp produces HLS for:
  - `/var/www/hls/autodj/`
  - `/var/www/hls/live/`
  - `/var/www/hls/current/` (public stable output)
- `radio-switchd` decides active source
- `radio-hls-relay` produces seamless `current/` playlist with monotonic seg IDs + discontinuities

## “If it works, don’t break it” Policy

- When a subsystem is confirmed working, **do not refactor/rewrite** it.
- Only add features or harden with minimal targeted patches.
- Any change must include: rollback note + verification commands.

## Required Output Format For Each Fix

When the user reports a problem, respond with:

1. **Diagnosis** (max 8 bullets, based on evidence from logs)
2. **Plan** (max 6 bullets)
3. **One bash script block** that:
   - is idempotent
   - backs up files it changes
   - restarts only the necessary services
4. **Verification block** (commands the user runs)
5. **Stop conditions** (what to paste back if failing)

## Known Services and Paths

Services (systemd):
- `liquidsoap-autodj`
- `autodj-video-overlay`
- `radio-switchd`
- `radio-hls-relay`
- `nginx`

Key paths:
- Music: `/var/lib/radio/music/{monday..sunday}/{morning,day,night}/` + `default/`
- Loops: `/var/lib/radio/loops/` (or fixed loop path when configured)
- HLS: `/var/www/hls/{autodj,live,current}/`
- Nowplaying JSON: `/var/www/radio/data/nowplaying.json`
- Active source: `/run/radio/active`

## Deployment Workflow (how updates reach VPS)

Preferred:
- Claude edits repo files locally (docs/scripts).
- User commits + pushes to GitHub.
- VPS pulls via `git pull --rebase` in `/root/radijas`.
- Then user runs the repo script (e.g. `./install/...` or `./redeploy.sh`) OR a provided one-off patch script.

If a new script is added, **tell the user exactly**:
- file path to commit
- how to run it on VPS
- and verification commands.

## Communication Style

- Be decisive.
- Do not ask “should I…?” if you can infer a safe default.
- If you need info, ask for the *single* most useful command output (max 2 commands).
