PeopleWeLike Radio — Working Build Manual (AutoDJ + Live + Seamless Switch without Refresh)
0) What this setup does (final working behavior)
AutoDJ runs 24/7 (Liquidsoap audio-only) and is always available.
AutoDJ audio is combined with a looping MP4 to create a program stream via ffmpeg (“overlay”) and published to nginx-rtmp.
A LIVE stream (e.g. Blackmagic Web Presenter 4K) can publish to the same server.
The web player always stays on a single HLS URL and switches between AutoDJ and LIVE without page refresh, within ~1–3 seconds.
Switching is done by a small daemon (radio-switchd) and a playlist/segment stabilizer (radio-hls-relay) so browsers never get stuck on old segment names.

1) Server identity (as observed)
Domain: radio.peoplewelike.club
Resolved IP: 72.60.181.89 (from getent ahosts)
RTMP port open: 1935/tcp (verified with nc -vz 72.60.181.89 1935)
nginx/rtmp is listening: 0.0.0.0:1935 (from ss -ltnp)

2) Directory layout (working paths)
HLS root
HLS_ROOT=/var/www/hls
HLS subfolders
AutoDJ HLS output: /var/www/hls/autodj
Live HLS output: /var/www/hls/live
Placeholder media: /var/www/hls/placeholder
“Current” (served to player): /var/www/hls/current
Important: the player should always use the same URL:
https://radio.peoplewelike.club/hls/current/index.m3u8
AutoDJ assets
Loop video used for overlay: /var/lib/liquidsoap/loop.mp4
Runtime + state
Active mode file: /run/radio/active
Relay state file: /var/lib/radio-hls-relay/state.json

3) nginx-rtmp config (exact working file you showed)
File: /etc/nginx/rtmp.conf
rtmp {
  server {
    listen 1935;
    chunk_size 4096;

    application live {
      live on;
# on_publish http://127.0.0.1:8088/auth;

      hls on;
      hls_path /var/www/hls/live;
      hls_fragment 6s;
      hls_playlist_length 120s;
      hls_cleanup on;
      hls_continuous on;

      exec_publish /usr/local/bin/hls-switch live;
      exec_publish_done /usr/local/bin/hls-switch autodj;
    }

    # Internal audio-only feed for overlay (localhost only)
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
      deny publish all;

        hls on;
        hls_path /var/www/hls/autodj;
        hls_fragment 6;
        hls_playlist_length 120;
        hls_cleanup on;
        hls_continuous on;
    }
  }
}

What each application does
live: external encoders publish here → HLS written to /var/www/hls/live
autodj_audio: Liquidsoap publishes audio-only here (localhost only)
autodj: ffmpeg overlay publishes combined video+audio here (localhost only) → HLS written to /var/www/hls/autodj

4) RTMP statistics endpoint (required by switch daemon)
You confirmed this works:
Local RTMP stat XML:
http://127.0.0.1:8089/rtmp_stat
Config file found:
/etc/nginx/conf.d/rtmp_stat.conf contains listen 127.0.0.1:8089;
Verification command:
nginx -t
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 20

radio-switchd uses this endpoint to read <nclients> for the live application.

5) Systemd services (exact units you showed)
5.1 Liquidsoap AutoDJ
systemctl cat liquidsoap-autodj returned:
File: /etc/systemd/system/liquidsoap-autodj.service
[Unit]
Description=Liquidsoap AutoDJ (audio-only) -> nginx-rtmp
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=liquidsoap
Group=liquidsoap
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/radio.liq
Restart=always
RestartSec=2
Nice=10
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/liquidsoap /var/www/radio/data

[Install]
WantedBy=multi-user.target

Drop-in override: /etc/systemd/system/liquidsoap-autodj.service.d/override.conf
[Service]
Restart=always
RestartSec=2
TimeoutStopSec=10
KillSignal=SIGINT

5.2 AutoDJ Video Overlay (ffmpeg)
File: /etc/systemd/system/autodj-video-overlay.service
[Unit]
Description=AutoDJ Overlay: loop MP4 video + AutoDJ audio -> nginx-rtmp autodj/index
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStart=/usr/local/bin/autodj-video-overlay
Restart=always
RestartSec=2
KillSignal=SIGINT
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target

5.3 Switching daemon (LIVE <-> AutoDJ) every 1 second
File: /etc/systemd/system/radio-switchd.service
[Unit]
Description=Radio switch daemon (LIVE <-> AutoDJ) every 1s
After=nginx.service
Wants=nginx.service

[Service]
Type=simple
ExecStart=/usr/local/bin/radio-switchd
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target

5.4 HLS relay (stable /hls/current without refresh)
File: /etc/systemd/system/radio-hls-relay.service
[Unit]
Description=Radio HLS relay (stable /hls/current playlist for seamless switching)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target


6) Executable scripts (exact working versions you pasted)
6.1 /usr/local/bin/autodj-video-overlay
Creates the AutoDJ program stream from:
Video: /var/lib/liquidsoap/loop.mp4
Audio: rtmp://127.0.0.1:1935/autodj_audio/stream?live=1
Output: rtmp://127.0.0.1:1935/autodj/index
#!/usr/bin/env bash
set -euo pipefail

LOOP_MP4="/var/lib/liquidsoap/loop.mp4"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

FPS=25
FRAG=6
GOP=$((FPS*FRAG))   # 150
FORCE_KF="expr:gte(t,n_forced*${FRAG})"

log(){ echo "[$(date -Is)] $*"; }

[[ -f "$LOOP_MP4" ]] || { log "Missing loop mp4: $LOOP_MP4"; exit 1; }

log "Starting overlay publish (no probe)."
log "Audio in: $AUDIO_IN"
log "Out:      $OUT"

exec ffmpeg -hide_banner -loglevel warning \
  -re -stream_loop -1 -i "$LOOP_MP4" \
  -thread_queue_size 1024 -i "$AUDIO_IN" \
  -map 0:v:0 -map 1:a:0 \
  -vf "scale=854:-2,fps=${FPS}" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
  -force_key_frames "${FORCE_KF}" \
  -b:v 1200k -maxrate 1200k -bufsize 2400k \
  -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
  -c:a aac -b:a 128k -ar 44100 -ac 2 \
  -muxdelay 0 -muxpreload 0 \
  -flvflags no_duration_filesize \
  -f flv "$OUT"


6.2 /usr/local/bin/radio-switchd
Writes live or autodj to /run/radio/active every second.
It considers LIVE healthy if:
live HLS exists and has segments, and
either nclients > 0 (from rtmp_stat) OR playlist mtime is fresh (≤ 8s)
#!/usr/bin/env bash
set -euo pipefail

HLS_ROOT="/var/www/hls"
LIVE_DIR="$HLS_ROOT/live"
AUTODJ_DIR="$HLS_ROOT/autodj"

ACTIVE_DIR="/run/radio"
ACTIVE_FILE="$ACTIVE_DIR/active"

RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"

log(){ echo "[$(date -Is)] $*"; }

latest_ts() {
  local m3u8="$1"
  awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$m3u8"
}

mtime_age_s() {
  local f="$1"
  local now m
  now="$(date +%s)"
  m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
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
  local v="$1"
  mkdir -p "$ACTIVE_DIR"
  printf "%s\n" "$v" >"${ACTIVE_FILE}.tmp"
  mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
}

is_live_healthy() {
  local m3u8 ts age lc
  m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  ts="$(latest_ts "$m3u8")"
  [[ -n "$ts" ]] || return 1
  [[ -f "$LIVE_DIR/$ts" ]] || return 1

  age="$(mtime_age_s "$m3u8")"
  lc="$(live_nclients || echo 0)"

  if [[ "${lc:-0}" -gt 0 ]]; then return 0; fi
  if [[ "$age" -le 8 ]]; then return 0; fi
  return 1
}

last=""
while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then
      set_active "live"
      last="live"
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


6.3 /usr/local/bin/radio-hls-relay (this is what removes the need to refresh)
This generates a stable playlist and stable segment names under /var/www/hls/current/.
It reads current mode from /run/radio/active
It reads source playlists from:
/var/www/hls/autodj/index.m3u8
/var/www/hls/live/index.m3u8
It writes:
/var/www/hls/current/index.m3u8
/var/www/hls/current/seg-<seq>.ts (symlinks to actual source ts files)
It inserts #EXT-X-DISCONTINUITY when switching sources.
#!/usr/bin/env python3
import os, time, json, math

HLS_ROOT="/var/www/hls"
SRC = {
  "autodj": os.path.join(HLS_ROOT, "autodj"),
  "live":   os.path.join(HLS_ROOT, "live"),
}
OUT_DIR = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")

ACTIVE_FILE="/run/radio/active"
STATE_FILE="/var/lib/radio-hls-relay/state.json"

WINDOW_SEGMENTS = 10
POLL = 0.5

def read_active():
  try:
    v = open(ACTIVE_FILE,"r").read().strip()
    return v if v in SRC else "autodj"
  except Exception:
    return "autodj"

def parse_m3u8(path):
  segs=[]
  dur=None
  try:
    with open(path,"r") as f:
      for line in f:
        line=line.strip()
        if line.startswith("#EXTINF:"):
          try:
            dur=float(line.split(":",1)[1].split(",",1)[0])
          except Exception:
            dur=None
        elif line.startswith("index-") and line.endswith(".ts"):
          if dur is None:
            dur=6.0
          segs.append((dur, line))
          dur=None
  except FileNotFoundError:
    return []
  return segs

def safe_stat(p):
  try:
    st=os.stat(p)
    return int(st.st_mtime), int(st.st_size)
  except Exception:
    return None

def load_state():
  try:
    with open(STATE_FILE,"r") as f:
      return json.load(f)
  except Exception:
    return {
      "next_seq": 0,
      "map": {},
      "window": [],
      "last_src": None
    }

def save_state(st):
  tmp=STATE_FILE+".tmp"
  with open(tmp,"w") as f:
    json.dump(st,f)
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
  maxdur=max([w["dur"] for w in window] + [6.0])
  target=int(math.ceil(maxdur))

  first_seq=window[0]["seq"]
  lines=[]
  lines.append("#EXTM3U")
  lines.append("#EXT-X-VERSION:3")
  lines.append(f"#EXT-X-TARGETDURATION:{target}")
  lines.append(f"#EXT-X-MEDIA-SEQUENCE:{first_seq}")

  for w in window:
    if w.get("disc"):
      lines.append("#EXT-X-DISCONTINUITY")
    lines.append(f"#EXTINF:{w['dur']:.3f},")
    lines.append(f"seg-{w['seq']}.ts")

  tmp=OUT_M3U8+".tmp"
  with open(tmp,"w") as f:
    f.write("\n".join(lines)+"\n")
  os.replace(tmp, OUT_M3U8)

def cleanup_symlinks(window):
  keep=set([f"seg-{w['seq']}.ts" for w in window] + ["index.m3u8"])
  try:
    for name in os.listdir(OUT_DIR):
      if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
        p=os.path.join(OUT_DIR,name)
        try:
          os.unlink(p)
        except Exception:
          pass
  except Exception:
    pass

def main():
  os.makedirs(OUT_DIR, exist_ok=True)
  st=load_state()

  while True:
    src=read_active()
    src_dir=SRC[src]
    src_m3u8=os.path.join(src_dir, "index.m3u8")

    segs=parse_m3u8(src_m3u8)
    segs=segs[-WINDOW_SEGMENTS:]

    source_changed = (st.get("last_src") is not None and st.get("last_src") != src)

    for dur, segname in segs:
      src_seg=os.path.join(src_dir, segname)
      ss=safe_stat(src_seg)
      if not ss:
        continue
      mtime,size=ss
      key=f"{src}:{segname}:{mtime}:{size}"
      if key not in st["map"]:
        seq=st["next_seq"]
        st["next_seq"] += 1
        st["map"][key]={"seq":seq,"dur":float(dur)}
        disc = False
        if source_changed:
          disc = True
          source_changed = False
        st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})

        out_seg=os.path.join(OUT_DIR, f"seg-{seq}.ts")
        ensure_symlink(out_seg, src_seg)

    if len(st["window"]) > WINDOW_SEGMENTS:
      st["window"] = st["window"][-WINDOW_SEGMENTS:]

    if st["window"]:
      write_playlist(st["window"])
      cleanup_symlinks(st["window"])

    st["last_src"]=src
    save_state(st)
    time.sleep(POLL)

if __name__ == "__main__":
  main()


6.4 /usr/local/bin/hls-switch
This is still in nginx-rtmp exec_publish hooks for live start/stop.
It flips /var/www/hls/current via symlink (with safety checks).
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
    autodj)
      do_switch "$AUTODJ_DIR"
      ;;
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
    placeholder)
      do_switch "$PLACEHOLDER_DIR"
      ;;
    *)
      echo "Usage: hls-switch {autodj|live|placeholder}" >&2
      exit 2
      ;;
  esac
) 9>"$lock"


7) How LIVE ingest is tested
Encoder settings used (what you tried)
RTMP Server:
rtmp://radio.peoplewelike.club:1935/live
Stream key:
index
So the published stream is:
rtmp://radio.peoplewelike.club:1935/live/index
Local ingest test (works when nginx accepts publish)
You used a local ffmpeg publish test:
timeout 15 ffmpeg -re -stream_loop -1 -i /var/lib/liquidsoap/loop.mp4 \
  -c:v libx264 -preset veryfast -tune zerolatency -c:a aac -f flv \
  rtmp://127.0.0.1:1935/live/index

When successful, nginx creates:
/var/www/hls/live/index.m3u8
/var/www/hls/live/index-*.ts

8) How “no refresh switching” works (final working flow)
The problem you saw earlier (and why refresh was needed)
When /hls/current/index.m3u8 suddenly points at a different folder (live vs autodj),
browsers can keep requesting old segment names (index-XX.ts) that no longer exist in the new source → 404 → player stuck loading.
The final fix
radio-switchd decides what should be active (live or autodj) and writes it to /run/radio/active.
radio-hls-relay generates a stable /var/www/hls/current/index.m3u8 that always references seg-.ts:
Segment names are monotonic and never “reset to index-0.ts” from the player’s perspective.
A #EXT-X-DISCONTINUITY is inserted when switching sources so the player decoder resets cleanly.
Result: same player URL keeps playing and swaps sources without reload.

9) Services present on your server (as listed)
From your system:
Core for operation:
liquidsoap-autodj.service
autodj-video-overlay.service
radio-switchd.service
radio-hls-relay.service
You also have additional helper services/timers installed (seen in /etc/systemd/system and /usr/local/bin), including:
radio-healthcheck.*
radio-hls-cleanup.*
radio-nowplaying.*
radio-music-sweep.*
radio-fifo.service
radio-liquidsoap.service
radio-ffmpeg-hls.service
radio-hls-relay.service
etc.
(Those exist on the box; the “seamless switching without refresh” is specifically driven by switchd + relay.)

10) Verification checklist (copy/paste commands)
A) Core services are up
systemctl is-active liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay

B) RTMP stat works (used for nclients)
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 20

C) AutoDJ HLS is producing segments
ls -lah /var/www/hls/autodj | head
curl -fsS https://radio.peoplewelike.club/hls/autodj/index.m3u8 | head -n 20

D) Live HLS exists only while publishing
ls -lah /var/www/hls/live | head
curl -fsS https://radio.peoplewelike.club/hls/live/index.m3u8 | head -n 20

E) The player URL stays constant
curl -fsS "https://radio.peoplewelike.club/hls/current/index.m3u8?ts=$(date +%s)" | head -n 30

F) Watch switching decisions in real time
journalctl -u radio-switchd -f


11) Backup “working state” bundle
This creates a reproducible archive of what matters most (nginx rtmp + stat + systemd units + scripts + loop video + relay state):
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p /root/backups

tar -czf "/root/backups/radio-working-$TS.tar.gz" \
  /etc/nginx/rtmp.conf \
  /etc/nginx/conf.d/rtmp_stat.conf \
  /etc/systemd/system/liquidsoap-autodj.service \
  /etc/systemd/system/liquidsoap-autodj.service.d \
  /etc/systemd/system/autodj-video-overlay.service \
  /etc/systemd/system/radio-switchd.service \
  /etc/systemd/system/radio-hls-relay.service \
  /usr/local/bin/autodj-video-overlay \
  /usr/local/bin/radio-switchd \
  /usr/local/bin/radio-hls-relay \
  /usr/local/bin/hls-switch \
  /var/lib/liquidsoap/loop.mp4 \
  /var/lib/radio-hls-relay/state.json \
  2>/dev/null || true

ls -lah "/root/backups/radio-working-$TS.tar.gz"


12) What the web player must use
To keep switching seamless, the front-end must always play:
https://radio.peoplewelike.club/hls/current/index.m3u8
(That is the whole point of the relay: one stable URL, no refresh.)
