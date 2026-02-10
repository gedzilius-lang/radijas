#!/usr/bin/env bash
###############################################################################
# deploy-fix.sh — Fix all broken components of People We Like Radio
# Paste into root shell on the production server.
# Safe to re-run (idempotent).
###############################################################################
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

log "=== People We Like Radio — Deploy Fix ==="
log "Host: $(hostname)"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root"; exit 1
fi

###############################################################################
# 1. DETECT LIQUIDSOAP VERSION
###############################################################################
log "--- Step 1: Detect Liquidsoap ---"
LIQ_VER="$(liquidsoap --version 2>&1 | head -1 || echo 'not found')"
log "Liquidsoap version: $LIQ_VER"

###############################################################################
# 2. ENSURE DIRECTORIES & PERMISSIONS
###############################################################################
log "--- Step 2: Directories & permissions ---"
mkdir -p /etc/liquidsoap /var/log/liquidsoap /var/lib/liquidsoap
mkdir -p /var/lib/radio/music/default /var/lib/radio/loops
mkdir -p /var/www/hls/{autodj,live,current,placeholder}
mkdir -p /var/www/radio/data
mkdir -p /var/www/radio.peoplewelike.club
mkdir -p /run/radio /var/lib/radio-hls-relay

touch /var/log/liquidsoap/radio.log
chown -R liquidsoap:audio /var/log/liquidsoap /etc/liquidsoap /var/lib/liquidsoap 2>/dev/null || true
chown -R www-data:www-data /var/www/hls /var/www/radio /var/www/radio.peoplewelike.club
chmod 775 /var/log/liquidsoap
chmod 644 /var/log/liquidsoap/radio.log

# Ensure schedule folders exist
for day in monday tuesday wednesday thursday friday saturday sunday; do
  for phase in morning day night; do
    mkdir -p "/var/lib/radio/music/${day}/${phase}"
  done
done
chown -R liquidsoap:audio /var/lib/radio/music 2>/dev/null || true

log "Directories OK"

###############################################################################
# 3. STOP SERVICES (to avoid stale state)
###############################################################################
log "--- Step 3: Stop services ---"
systemctl stop liquidsoap-autodj 2>/dev/null || true
systemctl stop autodj-video-overlay 2>/dev/null || true
systemctl stop radio-nowplayingd 2>/dev/null || true
systemctl stop radio-hls-relay 2>/dev/null || true
systemctl stop radio-switchd 2>/dev/null || true
log "Services stopped"

###############################################################################
# 4. WRITE LIQUIDSOAP CONFIG
###############################################################################
log "--- Step 4: Liquidsoap configuration ---"

cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ Configuration
# Compatible with Liquidsoap 2.0.x (.set() syntax)

# ─── Settings ───
settings.server.telnet.set(true)
settings.server.telnet.port.set(1234)
settings.log.file.set(true)
settings.log.file.path.set("/var/log/liquidsoap/radio.log")
settings.log.level.set(3)

# ─── Music library ───
music_root = "/var/lib/radio/music"

monday_morning    = "#{music_root}/monday/morning"
monday_day        = "#{music_root}/monday/day"
monday_night      = "#{music_root}/monday/night"
tuesday_morning   = "#{music_root}/tuesday/morning"
tuesday_day       = "#{music_root}/tuesday/day"
tuesday_night     = "#{music_root}/tuesday/night"
wednesday_morning = "#{music_root}/wednesday/morning"
wednesday_day     = "#{music_root}/wednesday/day"
wednesday_night   = "#{music_root}/wednesday/night"
thursday_morning  = "#{music_root}/thursday/morning"
thursday_day      = "#{music_root}/thursday/day"
thursday_night    = "#{music_root}/thursday/night"
friday_morning    = "#{music_root}/friday/morning"
friday_day        = "#{music_root}/friday/day"
friday_night      = "#{music_root}/friday/night"
saturday_morning  = "#{music_root}/saturday/morning"
saturday_day      = "#{music_root}/saturday/day"
saturday_night    = "#{music_root}/saturday/night"
sunday_morning    = "#{music_root}/sunday/morning"
sunday_day        = "#{music_root}/sunday/day"
sunday_night      = "#{music_root}/sunday/night"
default_folder    = "#{music_root}/default"

# ─── Playlist sources ───
def make_playlist(folder)
  playlist(mode="randomize", reload_mode="watch", folder)
end

pl_mon_morning = make_playlist(monday_morning)
pl_mon_day     = make_playlist(monday_day)
pl_mon_night   = make_playlist(monday_night)
pl_tue_morning = make_playlist(tuesday_morning)
pl_tue_day     = make_playlist(tuesday_day)
pl_tue_night   = make_playlist(tuesday_night)
pl_wed_morning = make_playlist(wednesday_morning)
pl_wed_day     = make_playlist(wednesday_day)
pl_wed_night   = make_playlist(wednesday_night)
pl_thu_morning = make_playlist(thursday_morning)
pl_thu_day     = make_playlist(thursday_day)
pl_thu_night   = make_playlist(thursday_night)
pl_fri_morning = make_playlist(friday_morning)
pl_fri_day     = make_playlist(friday_day)
pl_fri_night   = make_playlist(friday_night)
pl_sat_morning = make_playlist(saturday_morning)
pl_sat_day     = make_playlist(saturday_day)
pl_sat_night   = make_playlist(saturday_night)
pl_sun_morning = make_playlist(sunday_morning)
pl_sun_day     = make_playlist(sunday_day)
pl_sun_night   = make_playlist(sunday_night)
pl_default     = make_playlist(default_folder)
emergency      = blank(id="emergency")

# ─── Schedule switching ───
monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])

# ─── Audio processing ───
radio = crossfade(duration=3.0, scheduled)
radio = normalize(radio)

# ─── Output (no custom metadata callback — parsed from log by radio-nowplayingd) ───
output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF

chown liquidsoap:audio /etc/liquidsoap/radio.liq
chmod 644 /etc/liquidsoap/radio.liq
log "Liquidsoap config written"

###############################################################################
# 5. WRITE radio-nowplayingd DAEMON
###############################################################################
log "--- Step 5: radio-nowplayingd ---"

cat > /usr/local/bin/radio-nowplayingd <<'NPEOF'
#!/usr/bin/env bash
set -euo pipefail

# radio-nowplayingd — reads Liquidsoap log and writes nowplaying JSON
# Parses Liquidsoap's built-in log lines:
#   "Prepared" lines from playlist sources
#   Also supports TRACKMETA:/TRACKFILE: if present
# Checks log file first, falls back to journald.

ACTIVE="/run/radio/active"
LOGF="/var/log/liquidsoap/radio.log"
OUT="/var/www/radio/data/nowplaying.json"
OUT2="/var/www/radio/data/nowplaying"

mkdir -p "$(dirname "$OUT")"

write_json() {
  local mode="$1" artist="$2" title="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"mode":"%s","artist":"%s","title":"%s","updated":"%s"}\n' \
    "$mode" "$artist" "$title" "$ts" > "${OUT}.tmp"
  mv "${OUT}.tmp" "$OUT" || true
  cp "$OUT" "$OUT2" 2>/dev/null || true
}

parse_filename() {
  local base="$1"
  base="${base//_/ }"
  base="${base//-/ - }"  # handle Artist-Title (hyphen without spaces)
  if [[ "$base" == *" - "* ]]; then
    NP_ARTIST="${base%% - *}"
    NP_TITLE="${base#* - }"
  else
    NP_ARTIST="People We Like"
    NP_TITLE="$base"
  fi
}

write_json "autodj" "People We Like" "Loading..."

NP_ARTIST=""
NP_TITLE=""

while true; do
  mode="$(cat "$ACTIVE" 2>/dev/null || echo autodj)"

  if [[ "$mode" == "live" ]]; then
    write_json "live" "Live Broadcast" "LIVE SHOW"
    sleep 1
    continue
  fi

  line=""

  # Source 1: Liquidsoap log file
  if [[ -f "$LOGF" && -s "$LOGF" ]]; then
    line="$(grep -E 'TRACKMETA:|TRACKFILE:' "$LOGF" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
      line="$(grep -i 'Prepared' "$LOGF" 2>/dev/null | tail -n 1 || true)"
    fi
  fi

  # Source 2: journald fallback
  if [[ -z "$line" ]]; then
    line="$(journalctl -u liquidsoap-autodj --no-pager -n 300 -q 2>/dev/null \
      | grep -iE 'Prepared|TRACKMETA:|TRACKFILE:' | tail -n 1 || true)"
  fi

  if [[ -z "$line" ]]; then
    sleep 2
    continue
  fi

  if [[ "$line" == *"TRACKMETA:"* ]]; then
    val="${line#*TRACKMETA: }"
    NP_ARTIST="${val%% - *}"
    NP_TITLE="${val#* - }"
    [[ "$NP_ARTIST" == "$val" ]] && NP_ARTIST="People We Like"

  elif [[ "$line" == *"TRACKFILE:"* ]]; then
    file="${line#*TRACKFILE: }"
    base="$(basename "$file")"
    base="${base%.*}"
    parse_filename "$base"

  elif [[ "$line" == *"Prepared"* ]]; then
    # Extract quoted path:  ... Prepared "/path/to/file.mp3" ...
    filepath=""
    if echo "$line" | grep -qoP 'Prepared\s+"'; then
      filepath="$(echo "$line" | grep -oP 'Prepared\s+"\K[^"]+' || true)"
    fi
    if [[ -z "$filepath" ]]; then
      filepath="$(echo "$line" | sed -n 's/.*[Pp]repared[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p')"
    fi
    if [[ -n "$filepath" ]]; then
      base="$(basename "$filepath")"
      base="${base%.*}"
      parse_filename "$base"
    fi
  fi

  if [[ -n "$NP_TITLE" ]]; then
    write_json "autodj" "$NP_ARTIST" "$NP_TITLE"
  fi

  sleep 2
done
NPEOF
chmod +x /usr/local/bin/radio-nowplayingd
log "radio-nowplayingd installed"

###############################################################################
# 6. WRITE ALL OTHER DAEMON SCRIPTS (overlay, switchd, relay, ctl)
###############################################################################
log "--- Step 6: Other scripts ---"

# --- autodj-video-overlay ---
cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail
LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"
FPS=30; FRAG=6; GOP=$((FPS*FRAG))
FORCE_KF="expr:gte(t,n_forced*${FRAG})"
log(){ echo "[$(date -Is)] $*"; }
get_random_loop() {
  local loops=()
  while IFS= read -r -d '' file; do loops+=("$file"); done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
  [[ ${#loops[@]} -eq 0 ]] && return 1
  echo "${loops[$((RANDOM % ${#loops[@]}))]}"
}
log "Waiting for audio stream..."
for i in {1..60}; do
  curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio" && { log "Audio stream detected"; break; }
  sleep 2
done
while true; do
  LOOP_MP4=$(get_random_loop) || { log "No video loops, waiting..."; sleep 10; continue; }
  log "Starting overlay with: $(basename "$LOOP_MP4")"
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
    -muxdelay 0 -muxpreload 0 -flvflags no_duration_filesize \
    -f flv "$OUT" || true
  log "FFmpeg exited, restarting in 2s..."
  sleep 2
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay

# --- radio-switchd ---
cat > /usr/local/bin/radio-switchd <<'SWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; LIVE_DIR="$HLS_ROOT/live"; ACTIVE_DIR="/run/radio"; ACTIVE_FILE="$ACTIVE_DIR/active"
RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"
log(){ echo "[$(date -Is)] $*"; }
latest_ts(){ awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"; }
mtime_age_s(){ local now m; now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"; echo $(( now - m )); }
live_nclients(){ curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '$0~/<application>/{inapp=1;name=""} inapp&&$0~/<name>live<\/name>/{name="live"} name=="live"&&$0~/<nclients>/{gsub(/.*<nclients>|<\/nclients>.*/,"",$0);print $0;exit}' | tr -d '\r' | awk '{print ($1==""?0:$1)}'; }
set_active(){ mkdir -p "$ACTIVE_DIR"; printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"; mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"; }
is_live_healthy(){ local m3u8="$LIVE_DIR/index.m3u8"; [[ -f "$m3u8" ]] || return 1; grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1; local ts; ts="$(latest_ts "$m3u8")"; [[ -n "$ts" && -f "$LIVE_DIR/$ts" ]] || return 1; local age lc; age="$(mtime_age_s "$m3u8")"; lc="$(live_nclients || echo 0)"; [[ "${lc:-0}" -gt 0 ]] && return 0; [[ "$age" -le 8 ]] && return 0; return 1; }
mkdir -p "$ACTIVE_DIR"; last=""
while true; do
  if is_live_healthy; then [[ "$last" != "live" ]] && { set_active "live"; last="live"; log "ACTIVE -> live"; }
  else [[ "$last" != "autodj" ]] && { set_active "autodj"; last="autodj"; log "ACTIVE -> autodj"; }; fi
  sleep 1
done
SWITCHEOF
chmod +x /usr/local/bin/radio-switchd

# --- hls-switch (legacy hook) ---
cat > /usr/local/bin/hls-switch <<'HLSEOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; CURRENT="$HLS_ROOT/current"; mode="${1:-}"
has_real_ts(){ [[ -f "$1" ]] && grep -qE '^index-[0-9]+\.ts$' "$1"; }
do_switch(){ ln -sfn "$1" "$CURRENT"; chown -h www-data:www-data "$CURRENT" 2>/dev/null || true; }
lock="/run/hls-switch.lock"
( flock -w 10 9
  case "$mode" in
    autodj) do_switch "$HLS_ROOT/autodj" ;;
    live) for i in {1..10}; do has_real_ts "$HLS_ROOT/live/index.m3u8" && { do_switch "$HLS_ROOT/live"; exit 0; }; sleep 1; done; do_switch "$HLS_ROOT/autodj" ;;
    placeholder) do_switch "$HLS_ROOT/placeholder" ;;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2 ;;
  esac
) 9>"$lock"
HLSEOF
chmod +x /usr/local/bin/hls-switch

# --- radio-hls-relay (unchanged python script) ---
# Only write if it doesn't exist or is older than this script
cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""Radio HLS Relay - Seamless switching without page refresh"""
import os, time, json, math, sys
HLS_ROOT = "/var/www/hls"
SRC = {"autodj": os.path.join(HLS_ROOT, "autodj"), "live": os.path.join(HLS_ROOT, "live")}
OUT_DIR = os.path.join(HLS_ROOT, "current"); OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")
ACTIVE_FILE = "/run/radio/active"; STATE_FILE = "/var/lib/radio-hls-relay/state.json"
WINDOW_SEGMENTS = 10; POLL = 0.5

def read_active():
    try:
        v = open(ACTIVE_FILE).read().strip()
        return v if v in SRC else "autodj"
    except: return "autodj"

def parse_m3u8(path):
    segs, dur = [], None
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith("#EXTINF:"):
                try: dur = float(line.split(":",1)[1].split(",",1)[0])
                except: dur = None
            elif line.startswith("index-") and line.endswith(".ts"):
                segs.append((dur or 6.0, line)); dur = None
    except FileNotFoundError: pass
    return segs

def safe_stat(p):
    try:
        st = os.stat(p); return int(st.st_mtime), int(st.st_size)
    except: return None

def load_state():
    try:
        with open(STATE_FILE) as f: return json.load(f)
    except: return {"next_seq":0,"map":{},"window":[],"last_src":None}

def save_state(st):
    tmp = STATE_FILE+".tmp"; os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp,"w") as f: json.dump(st,f)
    os.replace(tmp, STATE_FILE)

def ensure_symlink(lnk, tgt):
    try:
        if os.path.islink(lnk) and os.readlink(lnk) == tgt: return
        if os.path.islink(lnk) or os.path.exists(lnk): os.unlink(lnk)
    except FileNotFoundError: pass
    os.symlink(tgt, lnk)

def write_playlist(window):
    if not window: return
    maxdur = max([w["dur"] for w in window]+[6.0]); target = int(math.ceil(maxdur))
    lines = ["#EXTM3U","#EXT-X-VERSION:3",f"#EXT-X-TARGETDURATION:{target}",f"#EXT-X-MEDIA-SEQUENCE:{window[0]['seq']}"]
    for w in window:
        if w.get("disc"): lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},"); lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8+".tmp"
    with open(tmp,"w") as f: f.write("\n".join(lines)+"\n")
    os.replace(tmp, OUT_M3U8)

def cleanup(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window]+["index.m3u8"])
    try:
        for n in os.listdir(OUT_DIR):
            if n not in keep and n.startswith("seg-") and n.endswith(".ts"):
                try: os.unlink(os.path.join(OUT_DIR,n))
                except: pass
    except: pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True); st = load_state()
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay started -> {OUT_M3U8}")
    while True:
        src = read_active(); src_dir = SRC[src]; src_m3u8 = os.path.join(src_dir,"index.m3u8")
        segs = parse_m3u8(src_m3u8)[-WINDOW_SEGMENTS:]
        source_changed = st.get("last_src") is not None and st.get("last_src") != src
        for dur, segname in segs:
            src_seg = os.path.join(src_dir, segname); ss = safe_stat(src_seg)
            if not ss: continue
            mtime, size = ss; key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]; st["next_seq"] += 1; st["map"][key] = {"seq":seq,"dur":float(dur)}
                disc = source_changed; source_changed = False
                if disc: print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Source -> {src}")
                st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})
                ensure_symlink(os.path.join(OUT_DIR,f"seg-{seq}.ts"), src_seg)
        if len(st["window"]) > WINDOW_SEGMENTS: st["window"] = st["window"][-WINDOW_SEGMENTS:]
        if len(st["map"]) > 100:
            for k in list(st["map"].keys())[:-50]: del st["map"][k]
        if st["window"]: write_playlist(st["window"]); cleanup(st["window"])
        st["last_src"] = src; save_state(st); time.sleep(POLL)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: sys.exit(0)
RELAYEOF
chmod +x /usr/local/bin/radio-hls-relay

# --- radio-ctl ---
cat > /usr/local/bin/radio-ctl <<'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd"
case "${1:-}" in
  start)   for s in $SERVICES; do systemctl start "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
  stop)    for s in $SERVICES; do systemctl stop "$s" || true; done ;;
  restart) for s in $SERVICES; do systemctl restart "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
  status)  for s in $SERVICES; do st=$(systemctl is-active "$s" 2>/dev/null||echo inactive); echo "  $s: $st"; done
           echo "  active-source: $(cat /run/radio/active 2>/dev/null||echo unknown)" ;;
  logs)    journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay -u radio-nowplayingd ;;
  *)       echo "Usage: radio-ctl {start|stop|restart|status|logs}" ;;
esac
CTLEOF
chmod +x /usr/local/bin/radio-ctl
log "All scripts installed"

###############################################################################
# 7. SYSTEMD SERVICES
###############################################################################
log "--- Step 7: Systemd services ---"

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
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/liquidsoap /var/log/liquidsoap
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/autodj-video-overlay.service <<'EOF'
[Unit]
Description=AutoDJ Video Overlay: loop MP4 + audio -> nginx-rtmp
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10
[Service]
Type=simple
User=root
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
Description=Radio switch daemon (LIVE <-> AutoDJ)
After=nginx.service
Wants=nginx.service
[Service]
Type=simple
User=root
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
Description=Radio HLS relay (stable /hls/current)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1
StateDirectory=radio-hls-relay
StateDirectoryMode=0755
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/radio-nowplayingd.service <<'EOF'
[Unit]
Description=Radio now-playing metadata daemon
After=liquidsoap-autodj.service radio-switchd.service
Wants=liquidsoap-autodj.service
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-nowplayingd
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd
log "Systemd services configured"

###############################################################################
# 8. NGINX CONFIG
###############################################################################
log "--- Step 8: Nginx ---"

# Only rewrite the radio vhost (don't touch rtmp.conf etc.)
cat > /etc/nginx/sites-available/radio.peoplewelike.club.conf <<'NGXEOF'
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club;
    root /var/www/radio.peoplewelike.club;
    index index.html;

    # HLS streaming
    location /hls {
        alias /var/www/hls;
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, OPTIONS';
        add_header Access-Control-Allow-Headers 'Range,Content-Type';
        add_header Access-Control-Expose-Headers 'Content-Length,Content-Range';
        location ~ \.m3u8$ {
            add_header Cache-Control "no-cache, no-store";
            add_header Access-Control-Allow-Origin *;
        }
        location ~ \.ts$ {
            add_header Cache-Control "max-age=86400";
            add_header Access-Control-Allow-Origin *;
        }
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    # API - serve JSON files from data directory
    # Handles /api/nowplaying.json AND /api/nowplaying (without extension)
    location = /api/nowplaying {
        alias /var/www/radio/data/nowplaying;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }
    location /api/ {
        alias /var/www/radio/data/;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
NGXEOF

ln -sf /etc/nginx/sites-available/radio.peoplewelike.club.conf /etc/nginx/sites-enabled/

if nginx -t 2>&1; then
  systemctl reload nginx
  log "Nginx config OK and reloaded"
else
  log "ERROR: Nginx config test failed!"
  nginx -t
  exit 1
fi

###############################################################################
# 9. SSL (certbot)
###############################################################################
log "--- Step 9: SSL ---"

if [[ -f /etc/letsencrypt/live/radio.peoplewelike.club/fullchain.pem ]]; then
  log "SSL cert already exists, skipping certbot"
else
  if command -v certbot &>/dev/null; then
    log "Running certbot..."
    certbot --nginx \
      -d radio.peoplewelike.club \
      -d stream.peoplewelike.club \
      --non-interactive \
      --agree-tos \
      --email admin@peoplewelike.club \
      --redirect \
      --keep-until-expiring || {
        log "WARNING: certbot failed (DNS may not point here yet). HTTP will still work."
      }
  else
    log "WARNING: certbot not installed. Run: apt install -y certbot python3-certbot-nginx"
  fi
fi

###############################################################################
# 10. INITIAL DATA FILES
###############################################################################
log "--- Step 10: Seed data files ---"

cat > /var/www/radio/data/nowplaying.json <<'EOF'
{"mode":"autodj","artist":"People We Like","title":"Starting...","updated":""}
EOF
cp /var/www/radio/data/nowplaying.json /var/www/radio/data/nowplaying
chown -R www-data:www-data /var/www/radio/data
chmod 644 /var/www/radio/data/*

###############################################################################
# 11. START SERVICES
###############################################################################
log "--- Step 11: Starting services ---"

systemctl restart nginx
sleep 1

systemctl start liquidsoap-autodj
sleep 5

# Check if Liquidsoap survived startup
if systemctl is-active --quiet liquidsoap-autodj; then
  log "Liquidsoap: RUNNING"
else
  log "ERROR: Liquidsoap failed to start! Checking logs..."
  journalctl -u liquidsoap-autodj -n 30 --no-pager
  echo ""
  echo "=== FIX: Check the error above and adjust /etc/liquidsoap/radio.liq ==="
  echo "=== Then run: systemctl restart liquidsoap-autodj ==="
  echo ""
fi

systemctl start autodj-video-overlay
sleep 1
systemctl start radio-switchd
sleep 1
systemctl start radio-hls-relay
sleep 1
systemctl start radio-nowplayingd
sleep 2

###############################################################################
# 12. VERIFY
###############################################################################
log "--- Step 12: Verification ---"
echo ""

ALL_OK=true
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd; do
  st="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  if [[ "$st" == "active" ]]; then
    echo "  OK  $svc"
  else
    echo "  FAIL $svc ($st)"
    ALL_OK=false
  fi
done

echo ""
echo "Active source: $(cat /run/radio/active 2>/dev/null || echo unknown)"
echo "AutoDJ HLS:    $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l) segments"
echo "Current HLS:   $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l) segments"
echo ""

echo "Now-playing JSON:"
cat /var/www/radio/data/nowplaying.json 2>/dev/null || echo "(not found)"
echo ""

echo "Liquidsoap log (last 10 lines):"
tail -10 /var/log/liquidsoap/radio.log 2>/dev/null || echo "(empty or missing)"
echo ""

# Test API via nginx
echo "API test (via nginx):"
curl -sS -H "Host: radio.peoplewelike.club" http://127.0.0.1/api/nowplaying 2>/dev/null || echo "(failed)"
echo ""

# Check ports
echo "Listening ports:"
ss -tlnp | grep -E '80|443|1935' || true
echo ""

if $ALL_OK; then
  log "=== ALL SERVICES RUNNING ==="
else
  log "=== SOME SERVICES FAILED — check errors above ==="
fi

echo ""
echo "If Liquidsoap failed, run:"
echo "  journalctl -u liquidsoap-autodj -n 50 --no-pager"
echo ""
echo "If SSL is needed, run:"
echo "  certbot --nginx -d radio.peoplewelike.club -d stream.peoplewelike.club"
echo ""
echo "Player: https://radio.peoplewelike.club/"
echo "Stream: https://radio.peoplewelike.club/hls/current/index.m3u8"
echo "API:    https://radio.peoplewelike.club/api/nowplaying.json"
echo ""
