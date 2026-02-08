#!/usr/bin/env bash
###############################################################################
# CREATE UTILITY SCRIPTS
# People We Like Radio Installation - Step 5
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Creating Utility Scripts"
echo "=============================================="

# ============================================
# 1. AutoDJ Video Overlay Script
# ============================================
echo "[1/5] Creating autodj-video-overlay script..."
cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail

# Configuration
LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

FPS=30
FRAG=6
GOP=$((FPS*FRAG))   # 180 frames
FORCE_KF="expr:gte(t,n_forced*${FRAG})"

log(){ echo "[$(date -Is)] $*"; }

# Function to get random video loop
get_random_loop() {
    local loops=()
    while IFS= read -r -d '' file; do
        loops+=("$file")
    done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)

    if [[ ${#loops[@]} -eq 0 ]]; then
        log "ERROR: No .mp4 files found in $LOOPS_DIR"
        return 1
    fi

    # Random selection
    local idx=$((RANDOM % ${#loops[@]}))
    echo "${loops[$idx]}"
}

# Wait for audio stream to be available
log "Waiting for audio stream..."
for i in {1..60}; do
    if curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio"; then
        log "Audio stream detected"
        break
    fi
    sleep 2
done

# Main loop - restart ffmpeg if it dies, pick new random loop
while true; do
    LOOP_MP4=$(get_random_loop)
    if [[ -z "$LOOP_MP4" ]]; then
        log "No video loops available, waiting..."
        sleep 10
        continue
    fi

    log "Starting overlay with loop: $(basename "$LOOP_MP4")"
    log "Audio in: $AUDIO_IN"
    log "Out:      $OUT"

    # Run ffmpeg
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
      -muxdelay 0 -muxpreload 0 \
      -flvflags no_duration_filesize \
      -f flv "$OUT" || true

    log "FFmpeg exited, restarting in 2 seconds..."
    sleep 2
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay
echo "    Created /usr/local/bin/autodj-video-overlay"

# ============================================
# 2. Radio Switch Daemon
# ============================================
echo "[2/5] Creating radio-switchd script..."
cat > /usr/local/bin/radio-switchd <<'SWITCHEOF'
#!/usr/bin/env bash
set -euo pipefail

HLS_ROOT="/var/www/hls"
LIVE_DIR="$HLS_ROOT/live"
AUTODJ_DIR="$HLS_ROOT/autodj"

ACTIVE_DIR="/run/radio"
ACTIVE_FILE="$ACTIVE_DIR/active"
NOWPLAYING_FILE="/var/www/radio/data/nowplaying.json"

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

update_nowplaying_live() {
  # When live, update nowplaying to show LIVE-SHOW
  if [[ -f "$NOWPLAYING_FILE" ]]; then
    cat > "${NOWPLAYING_FILE}.tmp" <<LIVEEOF
{"title":"LIVE-SHOW","artist":"Live Broadcast","mode":"live","updated":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
LIVEEOF
    mv "${NOWPLAYING_FILE}.tmp" "$NOWPLAYING_FILE"
  fi
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

mkdir -p "$ACTIVE_DIR"
last=""

while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then
      set_active "live"
      last="live"
      update_nowplaying_live
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
SWITCHEOF
chmod +x /usr/local/bin/radio-switchd
echo "    Created /usr/local/bin/radio-switchd"

# ============================================
# 3. HLS Switch (legacy hook)
# ============================================
echo "[3/5] Creating hls-switch script..."
cat > /usr/local/bin/hls-switch <<'HLSSWITCHEOF'
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
HLSSWITCHEOF
chmod +x /usr/local/bin/hls-switch
echo "    Created /usr/local/bin/hls-switch"

# ============================================
# 4. Radio HLS Relay (Python)
# ============================================
echo "[4/5] Creating radio-hls-relay script..."
cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""
Radio HLS Relay - Seamless switching without page refresh
Generates stable /hls/current with monotonic segment IDs
"""
import os
import time
import json
import math
import sys

HLS_ROOT = "/var/www/hls"
SRC = {
    "autodj": os.path.join(HLS_ROOT, "autodj"),
    "live":   os.path.join(HLS_ROOT, "live"),
}
OUT_DIR = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")

ACTIVE_FILE = "/run/radio/active"
STATE_FILE = "/var/lib/radio-hls-relay/state.json"

WINDOW_SEGMENTS = 10
POLL = 0.5

def read_active():
    try:
        v = open(ACTIVE_FILE, "r").read().strip()
        return v if v in SRC else "autodj"
    except Exception:
        return "autodj"

def parse_m3u8(path):
    segs = []
    dur = None
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXTINF:"):
                    try:
                        dur = float(line.split(":", 1)[1].split(",", 1)[0])
                    except Exception:
                        dur = None
                elif line.startswith("index-") and line.endswith(".ts"):
                    if dur is None:
                        dur = 6.0
                    segs.append((dur, line))
                    dur = None
    except FileNotFoundError:
        return []
    return segs

def safe_stat(p):
    try:
        st = os.stat(p)
        return int(st.st_mtime), int(st.st_size)
    except Exception:
        return None

def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {
            "next_seq": 0,
            "map": {},
            "window": [],
            "last_src": None
        }

def save_state(st):
    tmp = STATE_FILE + ".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(st, f)
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
    maxdur = max([w["dur"] for w in window] + [6.0])
    target = int(math.ceil(maxdur))

    first_seq = window[0]["seq"]
    lines = []
    lines.append("#EXTM3U")
    lines.append("#EXT-X-VERSION:3")
    lines.append(f"#EXT-X-TARGETDURATION:{target}")
    lines.append(f"#EXT-X-MEDIA-SEQUENCE:{first_seq}")

    for w in window:
        if w.get("disc"):
            lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},")
        lines.append(f"seg-{w['seq']}.ts")

    tmp = OUT_M3U8 + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, OUT_M3U8)

def cleanup_symlinks(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window] + ["index.m3u8"])
    try:
        for name in os.listdir(OUT_DIR):
            if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
                p = os.path.join(OUT_DIR, name)
                try:
                    os.unlink(p)
                except Exception:
                    pass
    except Exception:
        pass

def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()

    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Radio HLS Relay started")
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Output: {OUT_M3U8}")

    while True:
        src = read_active()
        src_dir = SRC[src]
        src_m3u8 = os.path.join(src_dir, "index.m3u8")

        segs = parse_m3u8(src_m3u8)
        segs = segs[-WINDOW_SEGMENTS:]

        source_changed = (st.get("last_src") is not None and st.get("last_src") != src)

        for dur, segname in segs:
            src_seg = os.path.join(src_dir, segname)
            ss = safe_stat(src_seg)
            if not ss:
                continue
            mtime, size = ss
            key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]
                st["next_seq"] += 1
                st["map"][key] = {"seq": seq, "dur": float(dur)}
                disc = False
                if source_changed:
                    disc = True
                    source_changed = False
                    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Source switched to: {src}")
                st["window"].append({"seq": seq, "dur": float(dur), "disc": disc})

                out_seg = os.path.join(OUT_DIR, f"seg-{seq}.ts")
                ensure_symlink(out_seg, src_seg)

        if len(st["window"]) > WINDOW_SEGMENTS:
            st["window"] = st["window"][-WINDOW_SEGMENTS:]

        # Clean old map entries (keep last 100)
        if len(st["map"]) > 100:
            keys = list(st["map"].keys())
            for k in keys[:-50]:
                del st["map"][k]

        if st["window"]:
            write_playlist(st["window"])
            cleanup_symlinks(st["window"])

        st["last_src"] = src
        save_state(st)
        time.sleep(POLL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay stopped")
        sys.exit(0)
RELAYEOF
chmod +x /usr/local/bin/radio-hls-relay
echo "    Created /usr/local/bin/radio-hls-relay"

# ============================================
# 5. Radio Now-Playing Daemon
# ============================================
echo "[5/6] Creating radio-nowplayingd script..."
cat > /usr/local/bin/radio-nowplayingd <<'NPEOF'
#!/usr/bin/env bash
set -euo pipefail

# radio-nowplayingd — reads Liquidsoap log and journald for track info
# Parses Liquidsoap's built-in log lines:
#   - 'Prepared "/path/to/Artist - Title.mp3"'
#   - 'TRACKMETA: Artist - Title'  (if custom callback exists)
#   - 'TRACKFILE: /path/to/file'   (if custom callback exists)
# Also checks journald as fallback if log file doesn't exist.

ACTIVE="/run/radio/active"
LOGF="/var/log/liquidsoap/radio.log"
OUT="/var/www/radio/data/nowplaying.json"

mkdir -p "$(dirname "$OUT")"

write_json() {
  local mode="$1" artist="$2" title="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"mode":"%s","artist":"%s","title":"%s","updated":"%s"}\n' \
    "$mode" "$artist" "$title" "$ts" > "${OUT}.tmp"
  mv "${OUT}.tmp" "$OUT" || true
}

# Extract artist/title from a filename (without path or extension)
parse_filename() {
  local base="$1"
  base="${base//_/ }"
  if [[ "$base" == *" - "* ]]; then
    NP_ARTIST="${base%% - *}"
    NP_TITLE="${base#* - }"
  else
    NP_ARTIST="People We Like"
    NP_TITLE="$base"
  fi
}

# Start with loading state
write_json "autodj" "People We Like" "Loading..."

NP_ARTIST=""
NP_TITLE=""

while true; do
  mode="$(cat "$ACTIVE" 2>/dev/null || echo autodj)"

  # When live, show live broadcast metadata
  if [[ "$mode" == "live" ]]; then
    write_json "live" "Live Broadcast" "LIVE SHOW"
    sleep 1
    continue
  fi

  # Try to find latest track from log file or journald
  line=""

  # Source 1: Liquidsoap log file
  if [[ -f "$LOGF" ]]; then
    # Try custom TRACKMETA/TRACKFILE lines first
    line="$(grep -E 'TRACKMETA:|TRACKFILE:' "$LOGF" 2>/dev/null | tail -n 1 || true)"
    # Fallback: Liquidsoap built-in "Prepared" lines
    if [[ -z "$line" ]]; then
      line="$(grep -i 'Prepared' "$LOGF" 2>/dev/null | tail -n 1 || true)"
    fi
  fi

  # Source 2: journald fallback
  if [[ -z "$line" ]]; then
    line="$(journalctl -u liquidsoap-autodj --no-pager -n 200 2>/dev/null \
      | grep -iE 'Prepared|TRACKMETA:|TRACKFILE:|on_track' | tail -n 1 || true)"
  fi

  if [[ -z "$line" ]]; then
    write_json "autodj" "People We Like" "Loading..."
    sleep 2
    continue
  fi

  # Parse the line
  if [[ "$line" == *"TRACKMETA:"* ]]; then
    val="${line#*TRACKMETA: }"
    NP_ARTIST="${val%% - *}"
    NP_TITLE="${val#* - }"
    [[ "$NP_ARTIST" == "$val" ]] && NP_ARTIST="People We Like"
    [[ "$NP_TITLE" == "$val" ]] && NP_TITLE="$val"

  elif [[ "$line" == *"TRACKFILE:"* ]]; then
    file="${line#*TRACKFILE: }"
    base="$(basename "$file")"
    base="${base%.*}"
    parse_filename "$base"

  elif [[ "$line" == *"Prepared"* ]]; then
    # Liquidsoap logs: ... Prepared "/path/to/file.mp3" ...
    # Extract the quoted path
    filepath="$(echo "$line" | grep -oP 'Prepared\s+"?\K[^"]+' || true)"
    if [[ -z "$filepath" ]]; then
      # Try without quotes
      filepath="$(echo "$line" | sed -n 's/.*Prepared[[:space:]]*//p' | sed 's/[[:space:]].*//')"
    fi
    if [[ -n "$filepath" ]]; then
      base="$(basename "$filepath")"
      base="${base%.*}"
      parse_filename "$base"
    fi
  fi

  if [[ -n "$NP_TITLE" ]]; then
    write_json "autodj" "$NP_ARTIST" "$NP_TITLE"
  else
    write_json "autodj" "People We Like" "Loading..."
  fi

  sleep 2
done
NPEOF
chmod +x /usr/local/bin/radio-nowplayingd
echo "    Created /usr/local/bin/radio-nowplayingd"

# ============================================
# 6. Radio Control Script
# ============================================
echo "[6/6] Creating radio-ctl control script..."
cat > /usr/local/bin/radio-ctl <<'CTLEOF'
#!/usr/bin/env bash
# Radio Control Script - Manage radio services
set -euo pipefail

SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd"

usage() {
    echo "Usage: radio-ctl {start|stop|restart|status|logs}"
    echo ""
    echo "Commands:"
    echo "  start   - Start all radio services"
    echo "  stop    - Stop all radio services"
    echo "  restart - Restart all radio services"
    echo "  status  - Show status of all services"
    echo "  logs    - Follow logs from all services"
    echo ""
    echo "Services managed: $SERVICES"
}

case "${1:-}" in
    start)
        echo "Starting radio services..."
        for svc in $SERVICES; do
            echo "  Starting $svc..."
            systemctl start "$svc" || true
        done
        sleep 2
        systemctl is-active $SERVICES || true
        ;;
    stop)
        echo "Stopping radio services..."
        for svc in $SERVICES; do
            echo "  Stopping $svc..."
            systemctl stop "$svc" || true
        done
        ;;
    restart)
        echo "Restarting radio services..."
        for svc in $SERVICES; do
            echo "  Restarting $svc..."
            systemctl restart "$svc" || true
        done
        sleep 2
        systemctl is-active $SERVICES || true
        ;;
    status)
        echo "Radio services status:"
        echo ""
        for svc in $SERVICES; do
            status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            if [[ "$status" == "active" ]]; then
                echo "  ✓ $svc: $status"
            else
                echo "  ✗ $svc: $status"
            fi
        done
        echo ""
        echo "Active source: $(cat /run/radio/active 2>/dev/null || echo 'unknown')"
        echo ""
        echo "HLS check:"
        echo "  AutoDJ: $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l) segments"
        echo "  Live:   $(ls /var/www/hls/live/*.ts 2>/dev/null | wc -l) segments"
        echo "  Current: $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l) segments"
        ;;
    logs)
        echo "Following radio service logs (Ctrl+C to exit)..."
        journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay
        ;;
    *)
        usage
        exit 1
        ;;
esac
CTLEOF
chmod +x /usr/local/bin/radio-ctl
echo "    Created /usr/local/bin/radio-ctl"

echo ""
echo "=============================================="
echo "  Utility Scripts Created"
echo "=============================================="
echo ""
echo "Scripts installed:"
echo "  /usr/local/bin/autodj-video-overlay - Video overlay generator"
echo "  /usr/local/bin/radio-switchd        - Live/AutoDJ switch daemon"
echo "  /usr/local/bin/hls-switch           - Legacy switch hook"
echo "  /usr/local/bin/radio-hls-relay      - Seamless HLS relay"
echo "  /usr/local/bin/radio-nowplayingd    - Now-playing metadata daemon"
echo "  /usr/local/bin/radio-ctl            - Service control utility"
echo ""
echo "Next step: Run ./06-create-services.sh"
