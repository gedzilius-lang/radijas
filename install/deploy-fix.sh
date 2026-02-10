#!/usr/bin/env bash
###############################################################################
# deploy-fix.sh — Professional Broadcast Deployment
# People We Like Radio — All-in-one fix & verification script
#
# Signal chain:
#   Liquidsoap (MP3→audio) ──output.external──▶ FFmpeg (WAV→AAC)
#       ──▶ RTMP autodj_audio/stream
#   FFmpeg overlay (loop.mp4 + autodj_audio) ──▶ RTMP autodj/index
#   nginx-rtmp ──▶ HLS /var/www/hls/autodj/
#   radio-hls-relay ──▶ /var/www/hls/current/  (stable, monotonic)
#   Player ──▶ /hls/current/index.m3u8
#
# Tested on: Liquidsoap 2.0.2, Ubuntu 22.04, nginx-rtmp
# Safe to re-run (idempotent).
###############################################################################
set -euo pipefail

# ─── Output helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GRN}OK${NC}  $*"; }
warn() { echo -e "  ${YLW}WARN${NC} $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*"; }

DIVIDER="══════════════════════════════════════════════════════════════"

###############################################################################
# PHASE 0 — PRE-CHECKS
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 0: Pre-flight checks"
echo "$DIVIDER"

if [[ $EUID -ne 0 ]]; then
  fail "Must run as root"; exit 1
fi
ok "Running as root"

# Detect Liquidsoap
LIQ_BIN="$(command -v liquidsoap 2>/dev/null || echo '')"
if [[ -z "$LIQ_BIN" ]]; then
  fail "Liquidsoap not installed. Run: apt install -y liquidsoap"; exit 1
fi
LIQ_VER="$(liquidsoap --version 2>&1 | head -1)"
ok "Liquidsoap: $LIQ_VER"

# Detect FFmpeg
if ! command -v ffmpeg &>/dev/null; then
  fail "FFmpeg not installed. Run: apt install -y ffmpeg"; exit 1
fi
ok "FFmpeg: $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"

# Detect nginx + RTMP module
if ! command -v nginx &>/dev/null; then
  fail "nginx not installed. Run: apt install -y nginx libnginx-mod-rtmp"; exit 1
fi
if nginx -V 2>&1 | grep -q rtmp; then
  ok "nginx with RTMP module"
else
  warn "nginx RTMP module may not be loaded — install libnginx-mod-rtmp"
fi

# Check content
MUSIC_COUNT=$(find /var/lib/radio/music -type f \( -name "*.mp3" -o -name "*.MP3" -o -name "*.flac" -o -name "*.ogg" -o -name "*.wav" \) 2>/dev/null | wc -l)
LOOP_COUNT=$(find /var/lib/radio/loops -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) 2>/dev/null | wc -l)
[[ "$MUSIC_COUNT" -gt 0 ]] && ok "Music files: $MUSIC_COUNT" || warn "No music files in /var/lib/radio/music/ (will play silence)"
[[ "$LOOP_COUNT" -gt 0 ]]  && ok "Video loops: $LOOP_COUNT"  || warn "No loop.mp4 in /var/lib/radio/loops/ (overlay will wait)"

###############################################################################
# PHASE 1 — STOP SERVICES
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 1: Stopping existing services"
echo "$DIVIDER"

for svc in radio-nowplayingd radio-hls-relay radio-switchd autodj-video-overlay liquidsoap-autodj; do
  systemctl stop "$svc" 2>/dev/null && ok "Stopped $svc" || true
done

###############################################################################
# PHASE 2 — DIRECTORIES & PERMISSIONS
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 2: Directories & permissions"
echo "$DIVIDER"

# System users
if ! id "liquidsoap" &>/dev/null; then
  useradd -r -s /bin/false -d /var/lib/liquidsoap liquidsoap 2>/dev/null || true
  usermod -aG audio liquidsoap 2>/dev/null || true
fi
if ! id "radio" &>/dev/null; then
  useradd -r -s /bin/false -d /var/lib/radio radio 2>/dev/null || true
  usermod -aG audio radio 2>/dev/null || true
fi

mkdir -p /etc/liquidsoap /var/log/liquidsoap /var/lib/liquidsoap
mkdir -p /var/lib/radio/music/default /var/lib/radio/loops
mkdir -p /var/www/hls/{autodj,live,current,placeholder}
mkdir -p /var/www/radio/data
mkdir -p /var/www/radio.peoplewelike.club
mkdir -p /run/radio /var/lib/radio-hls-relay
mkdir -p /etc/radio

for day in monday tuesday wednesday thursday friday saturday sunday; do
  for phase in morning day night; do
    mkdir -p "/var/lib/radio/music/${day}/${phase}"
  done
done

touch /var/log/liquidsoap/radio.log
chown -R liquidsoap:audio /var/log/liquidsoap /etc/liquidsoap /var/lib/liquidsoap 2>/dev/null || true
chown -R liquidsoap:audio /var/lib/radio/music 2>/dev/null || true
chown -R www-data:www-data /var/www/hls /var/www/radio /var/www/radio.peoplewelike.club
chmod 775 /var/log/liquidsoap
chmod 664 /var/log/liquidsoap/radio.log

ok "Directories created and permissions set"

###############################################################################
# PHASE 3 — LIQUIDSOAP CONFIGURATION
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 3: Liquidsoap configuration"
echo "$DIVIDER"

cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio — AutoDJ
# Compatible with Liquidsoap 2.0.x (uses .set() syntax)

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
# morning 06-12, day 12-18, night 18-06
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

# ─── Output: pipe WAV to FFmpeg which pushes AAC to RTMP ───
# NOTE: output.url with %ffmpeg silently fails in Liquidsoap 2.0.2.
# output.external pipes audio reliably to an external process.
output.external(
  %wav,
  id="rtmp_out",
  fallible=true,
  "ffmpeg -hide_banner -loglevel warning -nostdin -f wav -i pipe:0 -c:a aac -b:a 128k -ar 44100 -ac 2 -f flv rtmp://127.0.0.1:1935/autodj_audio/stream",
  radio
)
LIQEOF

chown liquidsoap:audio /etc/liquidsoap/radio.liq
chmod 644 /etc/liquidsoap/radio.liq
ok "Written /etc/liquidsoap/radio.liq"

###############################################################################
# PHASE 4 — DAEMON SCRIPTS
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 4: Daemon scripts"
echo "$DIVIDER"

# ─── 4a. autodj-video-overlay ───
cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail
LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream"
OUT="rtmp://127.0.0.1:1935/autodj/index"
FPS=30; FRAG=6; GOP=$((FPS*FRAG))
FORCE_KF="expr:gte(t,n_forced*${FRAG})"

log(){ echo "[$(date -Is)] $*"; }

get_random_loop() {
  local loops=()
  while IFS= read -r -d '' f; do loops+=("$f"); done \
    < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
  [[ ${#loops[@]} -eq 0 ]] && return 1
  echo "${loops[$((RANDOM % ${#loops[@]}))]}"
}

# Wait for an active RTMP publisher on autodj_audio (not just config presence)
log "Waiting for audio publisher on RTMP autodj_audio..."
for i in {1..90}; do
  STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || true)"
  if echo "$STAT" | awk '/<name>autodj_audio<\/name>/,/<\/application>/' | grep -q '<publishing>'; then
    log "Audio publisher detected on autodj_audio"
    break
  fi
  # Fallback: check nclients > 0 (covers various nginx-rtmp stat formats)
  NC=$(echo "$STAT" | awk '/<name>autodj_audio<\/name>/,/<\/application>/' \
       | grep -oP '<nclients>\K[0-9]+' | head -1 || true)
  if [[ "${NC:-0}" -gt 0 ]]; then
    log "Audio clients detected on autodj_audio (nclients=$NC)"
    break
  fi
  sleep 2
done

while true; do
  LOOP_MP4=$(get_random_loop) || { log "No video loops in $LOOPS_DIR, waiting..."; sleep 10; continue; }
  log "Overlay: $(basename "$LOOP_MP4") + audio → RTMP autodj"

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

  log "FFmpeg exited, restarting in 3s..."
  sleep 3
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay
ok "autodj-video-overlay"

# ─── 4b. radio-switchd ───
cat > /usr/local/bin/radio-switchd <<'SWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; LIVE_DIR="$HLS_ROOT/live"
ACTIVE_DIR="/run/radio"; ACTIVE_FILE="$ACTIVE_DIR/active"
RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"

log(){ echo "[$(date -Is)] $*"; }

latest_ts(){ awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"; }

mtime_age_s(){
  local now m; now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
  echo $(( now - m ))
}

live_nclients(){
  curl -fsS "$RTMP_STAT_URL" 2>/dev/null \
    | awk '$0~/<application>/{inapp=1;name=""} inapp&&$0~/<name>live<\/name>/{name="live"} name=="live"&&$0~/<nclients>/{gsub(/.*<nclients>|<\/nclients>.*/,"",$0);print $0;exit}' \
    | tr -d '\r' | awk '{print ($1==""?0:$1)}'
}

set_active(){
  mkdir -p "$ACTIVE_DIR"
  printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"; mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
}

is_live_healthy(){
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

mkdir -p "$ACTIVE_DIR"; last=""
while true; do
  if is_live_healthy; then
    [[ "$last" != "live" ]] && { set_active "live"; last="live"; log "ACTIVE -> live"; }
  else
    [[ "$last" != "autodj" ]] && { set_active "autodj"; last="autodj"; log "ACTIVE -> autodj"; }
  fi
  sleep 1
done
SWITCHEOF
chmod +x /usr/local/bin/radio-switchd
ok "radio-switchd"

# ─── 4c. hls-switch (exec hook for nginx-rtmp on_publish) ───
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
ok "hls-switch"

# ─── 4d. radio-hls-relay ───
cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""Radio HLS Relay — Seamless switching with stable monotonic segment IDs."""
import os, time, json, math, sys

HLS_ROOT  = "/var/www/hls"
SRC       = {"autodj": os.path.join(HLS_ROOT, "autodj"),
             "live":   os.path.join(HLS_ROOT, "live")}
OUT_DIR   = os.path.join(HLS_ROOT, "current")
OUT_M3U8  = os.path.join(OUT_DIR, "index.m3u8")
ACTIVE    = "/run/radio/active"
STATE     = "/var/lib/radio-hls-relay/state.json"
WINDOW    = 10
POLL      = 0.5

def read_active():
    try:
        v = open(ACTIVE).read().strip()
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
        with open(STATE) as f: return json.load(f)
    except: return {"next_seq":0, "map":{}, "window":[], "last_src":None}

def save_state(st):
    tmp = STATE + ".tmp"
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(tmp, "w") as f: json.dump(st, f)
    os.replace(tmp, STATE)

def ensure_symlink(lnk, tgt):
    try:
        if os.path.islink(lnk) and os.readlink(lnk) == tgt: return
        if os.path.islink(lnk) or os.path.exists(lnk): os.unlink(lnk)
    except FileNotFoundError: pass
    os.symlink(tgt, lnk)

def write_playlist(window):
    if not window: return
    maxdur = max(w["dur"] for w in window)
    target = int(math.ceil(max(maxdur, 6.0)))
    lines = ["#EXTM3U", "#EXT-X-VERSION:3",
             f"#EXT-X-TARGETDURATION:{target}",
             f"#EXT-X-MEDIA-SEQUENCE:{window[0]['seq']}"]
    for w in window:
        if w.get("disc"): lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},")
        lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8 + ".tmp"
    with open(tmp, "w") as f: f.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT_M3U8)

def cleanup(window):
    keep = set(["index.m3u8"] + [f"seg-{w['seq']}.ts" for w in window])
    try:
        for n in os.listdir(OUT_DIR):
            if n not in keep and n.startswith("seg-") and n.endswith(".ts"):
                try: os.unlink(os.path.join(OUT_DIR, n))
                except: pass
    except: pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()
    ts = time.strftime('%Y-%m-%dT%H:%M:%S')
    print(f"[{ts}] Relay started -> {OUT_M3U8}", flush=True)
    while True:
        src = read_active(); src_dir = SRC[src]
        src_m3u8 = os.path.join(src_dir, "index.m3u8")
        segs = parse_m3u8(src_m3u8)[-WINDOW:]
        source_changed = st.get("last_src") is not None and st.get("last_src") != src
        for dur, segname in segs:
            src_seg = os.path.join(src_dir, segname)
            ss = safe_stat(src_seg)
            if not ss: continue
            mtime, size = ss
            key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]; st["next_seq"] += 1
                st["map"][key] = {"seq": seq, "dur": float(dur)}
                disc = source_changed; source_changed = False
                if disc:
                    ts = time.strftime('%Y-%m-%dT%H:%M:%S')
                    print(f"[{ts}] Source -> {src}", flush=True)
                st["window"].append({"seq": seq, "dur": float(dur), "disc": disc})
                ensure_symlink(os.path.join(OUT_DIR, f"seg-{seq}.ts"), src_seg)
        if len(st["window"]) > WINDOW: st["window"] = st["window"][-WINDOW:]
        if len(st["map"]) > 100:
            for k in list(st["map"].keys())[:-50]: del st["map"][k]
        if st["window"]:
            write_playlist(st["window"]); cleanup(st["window"])
        st["last_src"] = src; save_state(st)
        time.sleep(POLL)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: sys.exit(0)
RELAYEOF
chmod +x /usr/local/bin/radio-hls-relay
ok "radio-hls-relay"

# ─── 4e. radio-nowplayingd ───
cat > /usr/local/bin/radio-nowplayingd <<'NPEOF'
#!/usr/bin/env bash
set -euo pipefail
# Reads Liquidsoap log for track changes; writes nowplaying JSON.
# Parses built-in "Prepared" lines from Liquidsoap.
# Falls back to journald if log file is empty.

ACTIVE="/run/radio/active"
LOGF="/var/log/liquidsoap/radio.log"
OUT="/var/www/radio/data/nowplaying.json"
OUT2="/var/www/radio/data/nowplaying"

mkdir -p "$(dirname "$OUT")"

write_json() {
  local mode="$1" artist="$2" title="$3"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"mode":"%s","artist":"%s","title":"%s","updated":"%s"}\n' \
    "$mode" "$artist" "$title" "$ts" > "${OUT}.tmp"
  mv "${OUT}.tmp" "$OUT" || true
  cp "$OUT" "$OUT2" 2>/dev/null || true
}

parse_filename() {
  local base="$1"
  base="${base//_/ }"
  base="${base//-/ - }"
  if [[ "$base" == *" - "* ]]; then
    NP_ARTIST="${base%% - *}"
    NP_TITLE="${base#* - }"
  else
    NP_ARTIST="People We Like"
    NP_TITLE="$base"
  fi
}

write_json "autodj" "People We Like" "Starting..."
NP_ARTIST=""; NP_TITLE=""

while true; do
  mode="$(cat "$ACTIVE" 2>/dev/null || echo autodj)"

  if [[ "$mode" == "live" ]]; then
    write_json "live" "Live Broadcast" "LIVE SHOW"
    sleep 1; continue
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

  if [[ -z "$line" ]]; then sleep 2; continue; fi

  if [[ "$line" == *"TRACKMETA:"* ]]; then
    val="${line#*TRACKMETA: }"
    NP_ARTIST="${val%% - *}"
    NP_TITLE="${val#* - }"
    [[ "$NP_ARTIST" == "$val" ]] && NP_ARTIST="People We Like"
  elif [[ "$line" == *"TRACKFILE:"* ]]; then
    file="${line#*TRACKFILE: }"
    base="$(basename "$file")"; base="${base%.*}"
    parse_filename "$base"
  elif [[ "$line" == *"Prepared"* ]]; then
    filepath=""
    if echo "$line" | grep -qoP 'Prepared\s+"'; then
      filepath="$(echo "$line" | grep -oP 'Prepared\s+"\K[^"]+' || true)"
    fi
    if [[ -z "$filepath" ]]; then
      filepath="$(echo "$line" | sed -n 's/.*[Pp]repared[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p')"
    fi
    if [[ -n "$filepath" ]]; then
      base="$(basename "$filepath")"; base="${base%.*}"
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
ok "radio-nowplayingd"

# ─── 4f. radio-ctl ───
cat > /usr/local/bin/radio-ctl <<'CTLEOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd"
case "${1:-}" in
  start)   for s in $SERVICES; do systemctl start "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
  stop)    for s in $SERVICES; do systemctl stop "$s" || true; done ;;
  restart) for s in $SERVICES; do systemctl restart "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
  status)  echo "Radio services:"; for s in $SERVICES; do
             st=$(systemctl is-active "$s" 2>/dev/null||echo inactive)
             echo "  $s: $st"
           done
           echo "  active-source: $(cat /run/radio/active 2>/dev/null||echo unknown)"
           echo "  autodj HLS: $(ls /var/www/hls/autodj/*.ts 2>/dev/null|wc -l) segments"
           echo "  current HLS: $(ls /var/www/hls/current/*.ts 2>/dev/null|wc -l) segments" ;;
  logs)    journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay -u radio-nowplayingd ;;
  *)       echo "Usage: radio-ctl {start|stop|restart|status|logs}" ;;
esac
CTLEOF
chmod +x /usr/local/bin/radio-ctl
ok "radio-ctl"

###############################################################################
# PHASE 5 — SYSTEMD SERVICES
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 5: Systemd service units"
echo "$DIVIDER"

cat > /etc/systemd/system/liquidsoap-autodj.service <<'EOF'
[Unit]
Description=Liquidsoap AutoDJ (audio via output.external to RTMP)
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
Description=AutoDJ Video Overlay (loop.mp4 + audio to RTMP autodj)
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
Description=Radio HLS relay (stable /hls/current playlist)
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
systemctl enable liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd 2>/dev/null
ok "All service units installed and enabled"

###############################################################################
# PHASE 6 — NGINX CONFIGURATION
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 6: Nginx configuration"
echo "$DIVIDER"

# 6a. RTMP config (only if missing — don't overwrite working config)
if [[ ! -f /etc/nginx/rtmp.conf ]]; then
  log "Creating /etc/nginx/rtmp.conf (was missing)"
  cat > /etc/nginx/rtmp.conf <<'RTMPEOF'
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
            record off;
        }

        application autodj_audio {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny publish all;
            allow play 127.0.0.1;
            deny play all;
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
RTMPEOF
  # Ensure rtmp include in nginx.conf
  if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf; then
    echo -e "\n# RTMP streaming\ninclude /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
  fi
  ok "Created rtmp.conf"
else
  ok "rtmp.conf exists (not overwritten)"
fi

# 6b. RTMP stats endpoint (only if missing)
if [[ ! -f /etc/nginx/conf.d/rtmp_stat.conf ]]; then
  cat > /etc/nginx/conf.d/rtmp_stat.conf <<'STATEOF'
server {
    listen 127.0.0.1:8089;
    location /rtmp_stat { rtmp_stat all; }
}
STATEOF
  ok "Created rtmp_stat.conf"
else
  ok "rtmp_stat.conf exists"
fi

# 6c. RTMP auth endpoint (only if missing)
if [[ ! -f /etc/nginx/conf.d/rtmp_auth.conf ]]; then
  if [[ -f /etc/radio/credentials ]]; then
    source /etc/radio/credentials
    cat > /etc/nginx/conf.d/rtmp_auth.conf <<AUTHEOF
server {
    listen 127.0.0.1:8088;
    location /auth {
        set \$auth_ok 0;
        if (\$arg_name = "${STREAM_KEY}") { set \$auth_ok "\${auth_ok}1"; }
        if (\$arg_pwd = "${STREAM_PASSWORD}") { set \$auth_ok "\${auth_ok}1"; }
        if (\$auth_ok = "011") { return 200; }
        return 403;
    }
}
AUTHEOF
    ok "Created rtmp_auth.conf"
  else
    warn "No /etc/radio/credentials — skipping rtmp_auth.conf"
  fi
else
  ok "rtmp_auth.conf exists"
fi

# 6d. Radio vhost (always rewrite — this contains our API fixes)
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

    # API: exact match for /api/nowplaying (player fetches without .json)
    location = /api/nowplaying {
        alias /var/www/radio/data/nowplaying;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }
    # API: prefix match for /api/*.json
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
  ok "Nginx config tested and reloaded"
else
  fail "Nginx config test failed!"
  nginx -t
  exit 1
fi

###############################################################################
# PHASE 7 — SSL (certbot)
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 7: SSL certificates"
echo "$DIVIDER"

# Always run certbot after vhost rewrite — our config rewrite removes
# certbot's SSL directives, so they must be re-applied.
if command -v certbot &>/dev/null; then
  log "Running certbot --nginx ..."
  if certbot --nginx \
    -d radio.peoplewelike.club \
    -d stream.peoplewelike.club \
    --non-interactive \
    --agree-tos \
    --email admin@peoplewelike.club \
    --redirect \
    --keep-until-expiring 2>&1; then
    ok "SSL certificates applied"
  else
    warn "certbot failed — HTTP still works, no HTTPS"
  fi
  nginx -t 2>/dev/null && systemctl reload nginx
else
  warn "certbot not installed — no HTTPS. Run: apt install -y certbot python3-certbot-nginx"
fi

###############################################################################
# PHASE 8 — CLEAN STALE STATE
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 8: Cleaning stale state"
echo "$DIVIDER"

# Remove old relay state so it starts fresh
rm -f /var/lib/radio-hls-relay/state.json

# Remove old HLS segments from current/ (they're symlinks, harmless)
rm -f /var/www/hls/current/seg-*.ts /var/www/hls/current/index.m3u8 2>/dev/null || true

# Seed initial data files
cat > /var/www/radio/data/nowplaying.json <<'EOF'
{"mode":"autodj","artist":"People We Like","title":"Starting...","updated":""}
EOF
cp /var/www/radio/data/nowplaying.json /var/www/radio/data/nowplaying
chown -R www-data:www-data /var/www/radio/data
chmod 644 /var/www/radio/data/*

ok "Stale state cleaned, seed data written"

###############################################################################
# PHASE 9 — START SERVICES (ordered, with health checks)
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 9: Starting services"
echo "$DIVIDER"

# Helper: wait for a condition with timeout
wait_for() {
  local desc="$1" timeout="$2" check_cmd="$3"
  local i=0
  while [[ $i -lt $timeout ]]; do
    if eval "$check_cmd" 2>/dev/null; then
      ok "$desc (${i}s)"
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  warn "$desc — not ready after ${timeout}s"
  return 1
}

# 9a. Nginx
log "Starting nginx..."
systemctl restart nginx
sleep 1
if systemctl is-active --quiet nginx; then
  ok "nginx running"
else
  fail "nginx failed to start"; journalctl -u nginx -n 10 --no-pager; exit 1
fi

# 9b. Liquidsoap
log "Starting liquidsoap-autodj..."
systemctl start liquidsoap-autodj
sleep 3

if systemctl is-active --quiet liquidsoap-autodj; then
  ok "liquidsoap-autodj running"
else
  fail "Liquidsoap failed to start!"
  echo ""
  echo "=== Liquidsoap error log ==="
  journalctl -u liquidsoap-autodj -n 30 --no-pager
  echo ""
  echo "Fix /etc/liquidsoap/radio.liq and re-run this script."
  exit 1
fi

# 9c. Wait for Liquidsoap → RTMP autodj_audio connection
log "Waiting for audio stream on RTMP autodj_audio..."
RTMP_AUDIO_CHECK='STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || true)"; echo "$STAT" | awk "/<name>autodj_audio<\\/name>/,/<\\/application>/" | grep -qE "<nclients>[1-9]|<publishing>"'
if ! wait_for "RTMP autodj_audio connected" 30 "$RTMP_AUDIO_CHECK"; then
  echo ""
  echo "--- Liquidsoap log (output-related) ---"
  grep -iE 'output|rtmp|connect|error|fail|ffmpeg|external' /var/log/liquidsoap/radio.log 2>/dev/null | tail -20 || true
  echo ""
  echo "--- Recent log ---"
  tail -20 /var/log/liquidsoap/radio.log 2>/dev/null || true
  echo ""
  warn "Liquidsoap may not be sending audio to RTMP yet. Continuing..."
fi

# 9d. Video overlay
log "Starting autodj-video-overlay..."
systemctl start autodj-video-overlay
sleep 2
if systemctl is-active --quiet autodj-video-overlay; then
  ok "autodj-video-overlay running"
else
  warn "autodj-video-overlay failed (may need loop.mp4 in /var/lib/radio/loops/)"
fi

# 9e. Wait for HLS segments from nginx-rtmp
log "Waiting for HLS segments in /var/www/hls/autodj/ ..."
HLS_CHECK='ls /var/www/hls/autodj/*.ts 2>/dev/null | head -1 | grep -q .'
if ! wait_for "AutoDJ HLS segments generated" 45 "$HLS_CHECK"; then
  echo ""
  echo "--- Overlay log ---"
  journalctl -u autodj-video-overlay -n 15 --no-pager -q 2>/dev/null || true
  echo ""
  warn "No HLS segments yet. The overlay may still be connecting."
fi

# 9f. Switch daemon
log "Starting radio-switchd..."
systemctl start radio-switchd
sleep 1
ok "radio-switchd started"

# 9g. HLS relay
log "Starting radio-hls-relay..."
systemctl start radio-hls-relay
sleep 2

# Wait for relay to produce segments in /hls/current/
RELAY_CHECK='ls /var/www/hls/current/seg-*.ts 2>/dev/null | head -1 | grep -q .'
if ! wait_for "HLS relay producing /hls/current/ segments" 15 "$RELAY_CHECK"; then
  echo "--- Relay log ---"
  journalctl -u radio-hls-relay -n 10 --no-pager -q 2>/dev/null || true
fi

# 9h. Now-playing daemon
log "Starting radio-nowplayingd..."
systemctl start radio-nowplayingd
sleep 2
ok "radio-nowplayingd started"

###############################################################################
# PHASE 10 — COMPREHENSIVE VERIFICATION
###############################################################################
echo ""
echo "$DIVIDER"
log "PHASE 10: Verification"
echo "$DIVIDER"
echo ""

ALL_OK=true

echo "--- Service Status ---"
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd; do
  st="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  if [[ "$st" == "active" ]]; then
    ok "$svc"
  else
    fail "$svc ($st)"
    ALL_OK=false
  fi
done

echo ""
echo "--- RTMP Streams ---"
STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || echo '<empty/>')"
for app in autodj_audio autodj live; do
  APP_BLOCK="$(echo "$STAT" | awk "/<name>${app}<\\/name>/,/<\\/application>/")"
  NCVAL=$(echo "$APP_BLOCK" | grep -oP '<nclients>\K[0-9]+' | head -1 || true)
  if [[ "${NCVAL:-0}" -gt 0 ]]; then
    ok "rtmp/${app} — ${NCVAL} client(s)"
  else
    if [[ "$app" == "live" ]]; then
      echo -e "  ${YLW}--${NC}  rtmp/${app} — no live publisher (normal when autodj only)"
    else
      fail "rtmp/${app} — 0 clients"
      ALL_OK=false
    fi
  fi
done

echo ""
echo "--- HLS Output ---"
AUTODJ_SEGS=$(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)
CURRENT_SEGS=$(ls /var/www/hls/current/seg-*.ts 2>/dev/null | wc -l)
echo "  AutoDJ segments:  $AUTODJ_SEGS"
echo "  Current segments: $CURRENT_SEGS"
if [[ "$AUTODJ_SEGS" -gt 0 ]]; then ok "HLS pipeline producing segments"; else fail "No HLS segments"; ALL_OK=false; fi

echo ""
echo "--- Now-Playing API ---"
NP_JSON="$(cat /var/www/radio/data/nowplaying.json 2>/dev/null || echo '{}')"
echo "  File: $NP_JSON"
API_JSON="$(curl -sS -H 'Host: radio.peoplewelike.club' http://127.0.0.1/api/nowplaying 2>/dev/null || echo 'FAILED')"
echo "  API:  $API_JSON"
if echo "$API_JSON" | grep -q '"mode"'; then ok "API responding"; else fail "API not responding"; ALL_OK=false; fi

echo ""
echo "--- Listening Ports ---"
ss -tlnp 2>/dev/null | grep -E ':80 |:443 |:1935 ' | while read -r line; do echo "  $line"; done

echo ""
echo "--- Liquidsoap Log (last 10 lines) ---"
tail -10 /var/log/liquidsoap/radio.log 2>/dev/null || echo "  (empty)"

echo ""
echo "--- Overlay Log (last 5 lines) ---"
journalctl -u autodj-video-overlay -n 5 --no-pager -q 2>/dev/null || true

echo ""
echo "--- Relay Log (last 5 lines) ---"
journalctl -u radio-hls-relay -n 5 --no-pager -q 2>/dev/null || true

###############################################################################
# SUMMARY
###############################################################################
echo ""
echo "$DIVIDER"
if $ALL_OK; then
  echo -e "${GRN}  ALL SERVICES RUNNING — Radio is live!${NC}"
else
  echo -e "${YLW}  SOME ISSUES DETECTED — review output above${NC}"
fi
echo "$DIVIDER"
echo ""
echo "Useful commands:"
echo "  radio-ctl status              — check all services"
echo "  radio-ctl restart             — restart all services"
echo "  radio-ctl logs                — tail all service logs"
echo "  journalctl -u liquidsoap-autodj -f  — Liquidsoap live log"
echo "  tail -f /var/log/liquidsoap/radio.log"
echo ""
echo "URLs:"
echo "  Player:  https://radio.peoplewelike.club/"
echo "  HLS:     https://radio.peoplewelike.club/hls/current/index.m3u8"
echo "  API:     https://radio.peoplewelike.club/api/nowplaying"
echo ""
