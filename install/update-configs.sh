#!/usr/bin/env bash
###############################################################################
# update-configs.sh
# Updates ALL radio configs (nginx, liquidsoap, scripts, services) on VPS
# without reinstalling packages. Pulls latest from the repo.
#
# Usage (on VPS as root):
#   curl -fsSL https://raw.githubusercontent.com/gedzilius-lang/radijas/claude/setup-radio-agent-instructions-ghStP/install/update-configs.sh | bash
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK:${NC} $1"; }
step() { echo -e "\n${CYAN}>>> $1${NC}"; }

DOMAIN="${DOMAIN:-radio.peoplewelike.club}"
HLS_ROOT="${HLS_ROOT:-/var/www/hls}"

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root${NC}"; exit 1; fi

step "Stopping all radio services"
systemctl stop radio-hls-relay autodj-video-overlay radio-switchd liquidsoap-autodj 2>/dev/null || true
ok "Services stopped"

# ============================================================================
step "Updating Liquidsoap config"
# ============================================================================
mkdir -p /etc/liquidsoap
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

music_root = "/var/lib/radio/music"

def make_playlist(folder)
  playlist(mode="random", reload_mode="watch", folder)
end

pl_mon_morning = make_playlist("#{music_root}/monday/morning")
pl_mon_day     = make_playlist("#{music_root}/monday/day")
pl_mon_night   = make_playlist("#{music_root}/monday/night")
pl_tue_morning = make_playlist("#{music_root}/tuesday/morning")
pl_tue_day     = make_playlist("#{music_root}/tuesday/day")
pl_tue_night   = make_playlist("#{music_root}/tuesday/night")
pl_wed_morning = make_playlist("#{music_root}/wednesday/morning")
pl_wed_day     = make_playlist("#{music_root}/wednesday/day")
pl_wed_night   = make_playlist("#{music_root}/wednesday/night")
pl_thu_morning = make_playlist("#{music_root}/thursday/morning")
pl_thu_day     = make_playlist("#{music_root}/thursday/day")
pl_thu_night   = make_playlist("#{music_root}/thursday/night")
pl_fri_morning = make_playlist("#{music_root}/friday/morning")
pl_fri_day     = make_playlist("#{music_root}/friday/day")
pl_fri_night   = make_playlist("#{music_root}/friday/night")
pl_sat_morning = make_playlist("#{music_root}/saturday/morning")
pl_sat_day     = make_playlist("#{music_root}/saturday/day")
pl_sat_night   = make_playlist("#{music_root}/saturday/night")
pl_sun_morning = make_playlist("#{music_root}/sunday/morning")
pl_sun_day     = make_playlist("#{music_root}/sunday/day")
pl_sun_night   = make_playlist("#{music_root}/sunday/night")

pl_default = make_playlist("#{music_root}/default")
emergency  = blank(id="emergency")

monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])
radio = crossfade(duration=2.0, scheduled)

nowplaying_file = "/var/www/radio/data/nowplaying.json"
def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end
radio = metadata.map(write_nowplaying, radio)

output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF

cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLE'
#!/usr/bin/liquidsoap
settings.init.allow_root.set(true)
settings.log.stdout.set(true)
all_music = playlist(mode="random", reload_mode="watch", "/var/lib/radio/music")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=2.0, radio)
nowplaying_file = "/var/www/radio/data/nowplaying.json"
def write_nowplaying(m)
  title = m["title"]; artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end
radio = metadata.map(write_nowplaying, radio)
output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQSIMPLE

chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq
ok "Liquidsoap configs updated"

# ============================================================================
step "Updating daemon scripts"
# ============================================================================

cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail
LOOPS_DIR="/var/lib/radio/loops"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"
FPS=30; FRAG=6; GOP=$((FPS*FRAG)); FORCE_KF="expr:gte(t,n_forced*${FRAG})"
log(){ echo "[$(date -Is)] $*"; }
get_random_loop() {
    local loops=()
    while IFS= read -r -d '' file; do loops+=("$file")
    done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
    if [[ ${#loops[@]} -eq 0 ]]; then log "ERROR: No .mp4 files in $LOOPS_DIR"; return 1; fi
    echo "${loops[$((RANDOM % ${#loops[@]}))]}"
}
log "Waiting for audio stream..."
for i in {1..60}; do
    if curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | grep -q "autodj_audio"; then log "Audio stream detected"; break; fi
    sleep 2
done
while true; do
    LOOP_MP4=$(get_random_loop) || { sleep 10; continue; }
    log "Starting overlay with loop: $(basename "$LOOP_MP4")"
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
    log "FFmpeg exited, restarting in 2s..."
    sleep 2
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay

cat > /usr/local/bin/hls-switch <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"
CURRENT="$HLS_ROOT/current"
mode="${1:-}"
lock="/run/hls-switch.lock"
has_real_ts() { local m3u8="$1"; [[ -f "$m3u8" ]] || return 1; grep -qE '^(index|live|stream)-[0-9]+\.ts$' "$m3u8"; }
do_switch() { ln -sfn "$1" "$CURRENT"; chown -h www-data:www-data "$CURRENT" 2>/dev/null || true; }
(
  flock -w 10 9
  case "$mode" in
    autodj) do_switch "$HLS_ROOT/autodj" ;;
    live)
      for i in {1..10}; do
        if has_real_ts "$HLS_ROOT/live/index.m3u8"; then do_switch "$HLS_ROOT/live"; exit 0; fi
        sleep 1
      done
      do_switch "$HLS_ROOT/autodj" ;;
    placeholder) do_switch "$HLS_ROOT/placeholder" ;;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2 ;;
  esac
) 9>"$lock"
EOF
chmod +x /usr/local/bin/hls-switch

cat > /usr/local/bin/radio-switchd <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HLS_ROOT="/var/www/hls"; LIVE_DIR="$HLS_ROOT/live"; ACTIVE_DIR="/run/radio"
ACTIVE_FILE="$ACTIVE_DIR/active"; NOWPLAYING_FILE="/var/www/radio/data/nowplaying.json"
RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"
log(){ echo "[$(date -Is)] $*"; }
latest_ts(){ awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$1"; }
mtime_age_s(){ local now m; now="$(date +%s)"; m="$(stat -c %Y "$1" 2>/dev/null || echo 0)"; echo $(( now - m )); }
live_nclients(){
  curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '
    $0 ~ /<application>/ {inapp=1; name=""}
    inapp && $0 ~ /<name>live<\/name>/ {name="live"}
    name=="live" && $0 ~ /<nclients>/ { gsub(/.*<nclients>|<\/nclients>.*/,"",$0); print $0; exit }
  ' | tr -d '\r' | awk '{print ($1==""?0:$1)}'
}
set_active(){ mkdir -p "$ACTIVE_DIR"; printf "%s\n" "$1" >"${ACTIVE_FILE}.tmp"; mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"; }
update_nowplaying_live(){
  if [[ -f "$NOWPLAYING_FILE" ]]; then
    printf '{"title":"LIVE-SHOW","artist":"Live Broadcast","mode":"live"}' > "${NOWPLAYING_FILE}.tmp"
    mv "${NOWPLAYING_FILE}.tmp" "$NOWPLAYING_FILE"
  fi
}
is_live_healthy(){
  local m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  local ts; ts="$(latest_ts "$m3u8")"; [[ -n "$ts" && -f "$LIVE_DIR/$ts" ]] || return 1
  local age lc; age="$(mtime_age_s "$m3u8")"; lc="$(live_nclients || echo 0)"
  [[ "${lc:-0}" -gt 0 ]] && return 0; [[ "$age" -le 8 ]] && return 0; return 1
}
mkdir -p "$ACTIVE_DIR"; last=""
while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then set_active "live"; last="live"; update_nowplaying_live; log "ACTIVE -> live"; fi
  else
    if [[ "$last" != "autodj" ]]; then set_active "autodj"; last="autodj"; log "ACTIVE -> autodj"; fi
  fi
  sleep 1
done
EOF
chmod +x /usr/local/bin/radio-switchd

cat > /usr/local/bin/radio-hls-relay <<'RELAYEOF'
#!/usr/bin/env python3
"""Radio HLS Relay - monotonic segment IDs + discontinuity markers"""
import os, time, json, math, sys
HLS_ROOT = "/var/www/hls"
SRC = {"autodj": os.path.join(HLS_ROOT, "autodj"), "live": os.path.join(HLS_ROOT, "live")}
OUT_DIR  = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")
ACTIVE_FILE = "/run/radio/active"
STATE_FILE  = "/var/lib/radio-hls-relay/state.json"
WINDOW_SEGMENTS = 10; POLL = 0.5
def read_active():
    try:
        v = open(ACTIVE_FILE,"r").read().strip()
        return v if v in SRC else "autodj"
    except: return "autodj"
def parse_m3u8(path):
    segs, dur = [], None
    try:
        with open(path,"r") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXTINF:"):
                    try: dur = float(line.split(":",1)[1].split(",",1)[0])
                    except: dur = None
                elif line.startswith("index-") and line.endswith(".ts"):
                    segs.append((dur if dur else 6.0, line)); dur = None
    except FileNotFoundError: return []
    return segs
def safe_stat(p):
    try: st = os.stat(p); return int(st.st_mtime), int(st.st_size)
    except: return None
def load_state():
    try:
        with open(STATE_FILE,"r") as f: return json.load(f)
    except: return {"next_seq":0,"map":{},"window":[],"last_src":None}
def save_state(st):
    tmp = STATE_FILE+".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp,"w") as f: json.dump(st,f)
    os.replace(tmp, STATE_FILE)
def ensure_symlink(lp, tp):
    try:
        if os.path.islink(lp) or os.path.exists(lp):
            if os.path.islink(lp) and os.readlink(lp)==tp: return
            os.unlink(lp)
    except FileNotFoundError: pass
    os.symlink(tp, lp)
def write_playlist(window):
    if not window: return
    maxdur = max([w["dur"] for w in window]+[6.0])
    target = int(math.ceil(maxdur)); first_seq = window[0]["seq"]
    lines = ["#EXTM3U","#EXT-X-VERSION:3",f"#EXT-X-TARGETDURATION:{target}",f"#EXT-X-MEDIA-SEQUENCE:{first_seq}"]
    for w in window:
        if w.get("disc"): lines.append("#EXT-X-DISCONTINUITY")
        lines.append(f"#EXTINF:{w['dur']:.3f},"); lines.append(f"seg-{w['seq']}.ts")
    tmp = OUT_M3U8+".tmp"
    with open(tmp,"w") as f: f.write("\n".join(lines)+"\n")
    os.replace(tmp, OUT_M3U8)
def cleanup_symlinks(window):
    keep = set([f"seg-{w['seq']}.ts" for w in window]+["index.m3u8"])
    try:
        for name in os.listdir(OUT_DIR):
            if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
                try: os.unlink(os.path.join(OUT_DIR,name))
                except: pass
    except: pass
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Radio HLS Relay started")
    while True:
        src = read_active(); src_dir = SRC[src]
        segs = parse_m3u8(os.path.join(src_dir,"index.m3u8"))[-WINDOW_SEGMENTS:]
        source_changed = (st.get("last_src") is not None and st.get("last_src")!=src)
        for dur,segname in segs:
            src_seg = os.path.join(src_dir, segname); ss = safe_stat(src_seg)
            if not ss: continue
            mtime,size = ss; key = f"{src}:{segname}:{mtime}:{size}"
            if key not in st["map"]:
                seq = st["next_seq"]; st["next_seq"]+=1
                st["map"][key]={"seq":seq,"dur":float(dur)}
                disc = False
                if source_changed: disc=True; source_changed=False; print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Source switched to: {src}")
                st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})
                ensure_symlink(os.path.join(OUT_DIR,f"seg-{seq}.ts"), src_seg)
        if len(st["window"])>WINDOW_SEGMENTS: st["window"]=st["window"][-WINDOW_SEGMENTS:]
        if len(st["map"])>100:
            keys=list(st["map"].keys())
            for k in keys[:-50]: del st["map"][k]
        if st["window"]: write_playlist(st["window"]); cleanup_symlinks(st["window"])
        st["last_src"]=src; save_state(st); time.sleep(POLL)
if __name__=="__main__":
    try: main()
    except KeyboardInterrupt: print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Relay stopped"); sys.exit(0)
RELAYEOF
chmod +x /usr/local/bin/radio-hls-relay

cat > /usr/local/bin/radio-ctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SERVICES="liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay"
case "${1:-}" in
    start)   echo "Starting...";  for s in $SERVICES; do systemctl start "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
    stop)    echo "Stopping...";  for s in $SERVICES; do systemctl stop "$s"  || true; done ;;
    restart) echo "Restarting..."; for s in $SERVICES; do systemctl restart "$s" || true; done; sleep 2; systemctl is-active $SERVICES || true ;;
    status)
        for s in $SERVICES; do echo "  $s: $(systemctl is-active "$s" 2>/dev/null || echo inactive)"; done
        echo ""; echo "Active: $(cat /run/radio/active 2>/dev/null || echo unknown)"
        echo "AutoDJ segs: $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)"
        echo "Current segs: $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)" ;;
    logs) journalctl -f -u liquidsoap-autodj -u autodj-video-overlay -u radio-switchd -u radio-hls-relay ;;
    *) echo "Usage: radio-ctl {start|stop|restart|status|logs}"; exit 1 ;;
esac
EOF
chmod +x /usr/local/bin/radio-ctl
ok "All daemon scripts updated"

# ============================================================================
step "Reloading systemd and restarting services"
# ============================================================================
systemctl daemon-reload
systemctl reset-failed liquidsoap-autodj 2>/dev/null || true

systemctl restart nginx
sleep 1
systemctl start liquidsoap-autodj
sleep 5

if ! systemctl is-active --quiet liquidsoap-autodj; then
  echo -e "${RED}  Liquidsoap failed. Logs:${NC}"
  journalctl -u liquidsoap-autodj --no-pager -n 15
  exit 1
fi
ok "liquidsoap-autodj running"

systemctl start autodj-video-overlay; sleep 3
systemctl start radio-switchd
systemctl start radio-hls-relay
ok "All services started"

# ============================================================================
step "Verification"
# ============================================================================
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay; do
  echo "  $svc: $(systemctl is-active $svc 2>/dev/null || echo inactive)"
done

echo ""
echo "Waiting 15s for HLS segments..."
sleep 15
echo "  AutoDJ segments: $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)"
echo "  Current segments: $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)"
echo ""
echo -e "${GREEN}All configs updated. Test: https://${DOMAIN}/${NC}"
