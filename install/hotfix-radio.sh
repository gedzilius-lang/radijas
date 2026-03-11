#!/usr/bin/env bash
###############################################################################
# hotfix-radio.sh — Fix video overlay, deploy player, restart services
# People We Like Radio
#
# Key optimization: Pre-renders mp4 ONCE to broadcast spec, then plays back
# with -c:v copy (no real-time encoding). CPU drops from ~30% to ~2%.
#
# Run as root:  bash hotfix-radio.sh
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GRN}OK${NC}  $*"; }
warn() { echo -e "  ${YLW}WARN${NC} $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*"; }

if [[ $EUID -ne 0 ]]; then fail "Must run as root"; exit 1; fi

# ─── Config ──────────────────────────────────────────────────────────────────
LOOPS_DIR="/var/lib/radio/loops"
RENDER_DIR="${LOOPS_DIR}/rendered"
WEBROOT="/var/www/radio.peoplewelike.club"
FPS=30
FRAG=6
GOP=$((FPS*FRAG))   # 180 frames = 6s keyframe interval

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 1: Validate source video loops"
echo "════════════════════════════════════════════════════════════"

mkdir -p "$LOOPS_DIR" "$RENDER_DIR"
LOOP_COUNT=$(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) 2>/dev/null | wc -l)

if [[ "$LOOP_COUNT" -eq 0 ]]; then
  fail "No .mp4 files in $LOOPS_DIR"
  echo "  Upload at least one .mp4 file via SFTP to: $LOOPS_DIR"
  echo "  Requirements: any video file (will be pre-rendered to 1080p)"
  exit 1
fi

ok "Found $LOOP_COUNT source video loop(s)"
while IFS= read -r -d '' mp4; do
  FNAME="$(basename "$mp4")"
  FSIZE="$(stat -c %s "$mp4" 2>/dev/null || echo 0)"
  FSIZE_MB=$(( FSIZE / 1048576 ))
  V_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$mp4" 2>/dev/null || true)"
  V_RES="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$mp4" 2>/dev/null || true)"
  V_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp4" 2>/dev/null || true)"
  if [[ -z "$V_CODEC" ]]; then
    fail "$FNAME (${FSIZE_MB}MB) — NO VIDEO TRACK! Cannot use as overlay."
  else
    ok "$FNAME: ${FSIZE_MB}MB, codec=${V_CODEC}, res=${V_RES}, dur=${V_DUR%%.*}s"
  fi
done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 2: Pre-render videos to broadcast spec (one-time)"
echo "════════════════════════════════════════════════════════════"
echo "  Target: 1920x1080, ${FPS}fps, H.264 CBR 2500k, GOP ${GOP}"
echo "  This runs ONCE per file. Playback then uses -c:v copy (near-zero CPU)."
echo ""

RENDERED_COUNT=0
while IFS= read -r -d '' src; do
  FNAME="$(basename "$src")"
  RENDERED="${RENDER_DIR}/${FNAME}"
  SRC_MTIME="$(stat -c %Y "$src" 2>/dev/null || echo 0)"
  RND_MTIME="$(stat -c %Y "$RENDERED" 2>/dev/null || echo 0)"

  # Skip if rendered version exists and is newer than source
  if [[ -f "$RENDERED" && "$RND_MTIME" -ge "$SRC_MTIME" ]]; then
    RND_SIZE="$(stat -c %s "$RENDERED" 2>/dev/null || echo 0)"
    RND_MB=$(( RND_SIZE / 1048576 ))
    ok "$FNAME already rendered (${RND_MB}MB) — skipping"
    RENDERED_COUNT=$((RENDERED_COUNT + 1))
    continue
  fi

  # Check source has video track
  V_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$src" 2>/dev/null || true)"
  if [[ -z "$V_CODEC" ]]; then
    warn "$FNAME has no video track — skipping"
    continue
  fi

  log "Rendering $FNAME → broadcast spec..."
  RENDER_TMP="${RENDERED}.tmp.mp4"

  if ffmpeg -hide_banner -y \
    -i "$src" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
    -c:v libx264 -preset medium -pix_fmt yuv420p \
    -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${FRAG})" \
    -b:v 2500k -maxrate 2500k -bufsize 5000k \
    -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
    -an \
    -movflags +faststart \
    "$RENDER_TMP" 2>&1 | tail -5; then
    mv "$RENDER_TMP" "$RENDERED"
    RND_SIZE="$(stat -c %s "$RENDERED" 2>/dev/null || echo 0)"
    RND_MB=$(( RND_SIZE / 1048576 ))
    ok "$FNAME rendered successfully (${RND_MB}MB)"
    RENDERED_COUNT=$((RENDERED_COUNT + 1))
  else
    rm -f "$RENDER_TMP"
    fail "$FNAME render FAILED — check source file"
  fi
done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)

# Clean up rendered files whose source no longer exists
while IFS= read -r -d '' rnd; do
  FNAME="$(basename "$rnd")"
  SRC="${LOOPS_DIR}/${FNAME}"
  if [[ ! -f "$SRC" ]]; then
    rm -f "$rnd"
    warn "Removed orphan rendered file: $FNAME"
  fi
done < <(find "$RENDER_DIR" -maxdepth 1 -type f -name "*.mp4" -print0 2>/dev/null)

if [[ "$RENDERED_COUNT" -eq 0 ]]; then
  fail "No rendered videos available — overlay cannot start"
  exit 1
fi
echo ""
ok "Pre-rendered videos ready: $RENDERED_COUNT file(s) in $RENDER_DIR"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 3: Deploy player HTML"
echo "════════════════════════════════════════════════════════════"

mkdir -p "$WEBROOT"
log "Writing player with video.js HLS support..."
cat > "${WEBROOT}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>People We Like Radio</title>
<link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
<style>
:root{--bg:#0d0a1a;--card:#1a1329;--purple:#6b46c1;--purple-l:#9f7aea;--text:#e2e8f0;--muted:#a0aec0;--dim:#718096}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:Inter,-apple-system,BlinkMacSystemFont,sans-serif;background:var(--bg);min-height:100vh;color:var(--text);display:flex;align-items:center;justify-content:center;flex-direction:column;padding:20px}
.wrap{max-width:960px;width:100%}
header{text-align:center;padding:30px 0 20px}
.logo{font-size:2em;font-weight:700;background:linear-gradient(135deg,var(--purple-l),var(--purple));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
.tagline{color:var(--dim);font-size:.9em;letter-spacing:2px;text-transform:uppercase;margin-top:5px}
.player-card{background:var(--card);border-radius:16px;overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,.5);border:1px solid rgba(107,70,193,.2)}
.video-wrapper{position:relative;aspect-ratio:16/9;background:#000}
.video-wrapper.hidden{display:none}
.video-js{width:100%;height:100%}
.audio-mode{aspect-ratio:16/9;background:linear-gradient(135deg,var(--bg),var(--card));display:none;align-items:center;justify-content:center;flex-direction:column;gap:20px}
.audio-mode.active{display:flex}
.audio-vis{display:flex;align-items:flex-end;gap:4px;height:80px}
.audio-bar{width:8px;background:linear-gradient(to top,var(--purple),var(--purple-l));border-radius:4px;animation:ab .8s ease-in-out infinite}
@keyframes ab{0%,100%{height:20px}50%{height:60px}}
.audio-bar:nth-child(1){animation-delay:0s}.audio-bar:nth-child(2){animation-delay:.1s}.audio-bar:nth-child(3){animation-delay:.2s}.audio-bar:nth-child(4){animation-delay:.3s}.audio-bar:nth-child(5){animation-delay:.4s}.audio-bar:nth-child(6){animation-delay:.3s}.audio-bar:nth-child(7){animation-delay:.2s}.audio-bar:nth-child(8){animation-delay:.1s}
.audio-text{color:var(--muted);font-size:.9em}
.np{padding:20px;background:rgba(0,0,0,.3);display:flex;align-items:center;gap:16px}
.np-icon{width:50px;height:50px;background:linear-gradient(135deg,var(--purple),var(--purple-l));border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:24px;flex-shrink:0}
.np-info{flex:1;min-width:0}
.np-label{font-size:.7em;text-transform:uppercase;letter-spacing:2px;color:var(--dim);margin-bottom:4px}
.np-title{font-size:1.1em;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.np-artist{font-size:.9em;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.status{display:flex;align-items:center;gap:8px;padding:8px 16px;border-radius:20px;font-size:.75em;font-weight:600;text-transform:uppercase;letter-spacing:1px;background:rgba(107,70,193,.2);border:1px solid rgba(107,70,193,.4);color:var(--purple-l)}
.status.live{background:rgba(229,62,62,.2);border-color:rgba(229,62,62,.4);color:#e53e3e;animation:lg 1.5s ease-in-out infinite}
@keyframes lg{0%,100%{box-shadow:0 0 10px rgba(229,62,62,.6)}50%{box-shadow:0 0 25px rgba(229,62,62,.6),0 0 40px rgba(229,62,62,.6)}}
.status-dot{width:8px;height:8px;border-radius:50%;background:currentColor}
.status.live .status-dot{animation:blink 1s infinite}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}
.ctrls{padding:16px 20px;display:flex;gap:10px;flex-wrap:wrap;justify-content:center;border-top:1px solid rgba(107,70,193,.1)}
.btn{padding:12px 20px;border:none;border-radius:10px;font-size:.9em;font-weight:600;cursor:pointer;transition:all .2s}
.btn-p{background:linear-gradient(135deg,var(--purple),var(--purple-l));color:#fff}
.btn-p:hover{transform:translateY(-2px);box-shadow:0 10px 30px rgba(107,70,193,.4)}
.btn-s{background:rgba(107,70,193,.15);color:var(--purple-l);border:1px solid rgba(107,70,193,.3)}
.btn-s:hover{background:rgba(107,70,193,.25)}
.btn-s.on{background:rgba(107,70,193,.3);border-color:var(--purple-l)}
.stats{padding:12px 20px;display:flex;justify-content:space-between;align-items:center;background:rgba(0,0,0,.2);font-size:.85em;color:var(--muted)}
.ldot{width:8px;height:8px;background:#48bb78;border-radius:50%;display:inline-block;margin-right:6px;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.2);opacity:.7}}
footer{text-align:center;padding:30px 20px;color:var(--dim);font-size:.85em}
footer a{color:var(--purple-l);text-decoration:none}
.video-js .vjs-big-play-button{background:var(--purple);border:none;border-radius:50%;width:80px;height:80px;line-height:80px}
.video-js:hover .vjs-big-play-button{background:var(--purple-l)}
.video-js .vjs-control-bar{background:rgba(13,10,26,.9)}
.video-js .vjs-play-progress,.video-js .vjs-volume-level{background:var(--purple)}
</style>
</head>
<body>
<div class="wrap">
<header><div class="logo">People We Like</div><div class="tagline">Radio</div></header>
<div class="player-card">
  <div class="video-wrapper" id="vw">
    <video id="rp" class="video-js vjs-big-play-centered" controls preload="auto">
      <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
    </video>
  </div>
  <div class="audio-mode" id="am">
    <div class="audio-vis">
      <div class="audio-bar"></div><div class="audio-bar"></div><div class="audio-bar"></div><div class="audio-bar"></div>
      <div class="audio-bar"></div><div class="audio-bar"></div><div class="audio-bar"></div><div class="audio-bar"></div>
    </div>
    <div class="audio-text">Audio Only Mode</div>
  </div>
  <div class="np">
    <div class="np-icon">&#9835;</div>
    <div class="np-info">
      <div class="np-label" id="npl">Now Playing</div>
      <div class="np-title" id="npt">Loading...</div>
      <div class="np-artist" id="npa"></div>
    </div>
    <div class="status" id="si"><span class="status-dot"></span><span id="st">AutoDJ</span></div>
  </div>
  <div class="ctrls">
    <button class="btn btn-p" id="bp">Play</button>
    <button class="btn btn-s" id="bm">Mute</button>
    <button class="btn btn-s" id="bv">Video Off</button>
    <button class="btn btn-s" id="bf">Fullscreen</button>
  </div>
  <div class="stats"><div><span class="ldot"></span><span id="lc">-- listeners</span></div><div id="sq">1080p</div></div>
</div>
<footer>&copy; 2024 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></footer>
</div>
<script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
<script>
const p=videojs('rp',{liveui:true,html5:{vhs:{overrideNative:true,smoothQualityChange:true,allowSeeksWithinUnsafeLiveWindow:true},nativeAudioTracks:false,nativeVideoTracks:false},controls:true,autoplay:false,preload:'auto'});
const bp=document.getElementById('bp'),bm=document.getElementById('bm'),bv=document.getElementById('bv'),bf=document.getElementById('bf');
const vw=document.getElementById('vw'),am=document.getElementById('am');
let ve=true;
bp.onclick=()=>{p.paused()?p.play():p.pause()};
bm.onclick=()=>{p.muted(!p.muted());bm.textContent=p.muted()?'Unmute':'Mute';bm.classList.toggle('on',p.muted())};
bv.onclick=()=>{ve=!ve;vw.classList.toggle('hidden',!ve);am.classList.toggle('active',!ve);bv.textContent=ve?'Video Off':'Video On';bv.classList.toggle('on',!ve)};
bf.onclick=()=>{p.isFullscreen()?p.exitFullscreen():p.requestFullscreen()};
p.on('play',()=>{bp.textContent='Pause'});
p.on('pause',()=>{bp.textContent='Play'});
p.on('error',()=>{console.log('Stream error, recovering...');setTimeout(()=>{p.src({src:'/hls/current/index.m3u8',type:'application/x-mpegURL'});p.load()},3000)});
async function upd(){try{const r=await fetch('/api/nowplaying?'+Date.now());const d=await r.json();
if(d.mode==='live'){document.getElementById('npl').textContent='LIVE BROADCAST';document.getElementById('npt').textContent=d.title||'LIVE SHOW';document.getElementById('npa').textContent=d.artist||'';document.getElementById('st').textContent='LIVE';document.getElementById('si').className='status live'}
else{document.getElementById('npl').textContent='Now Playing';document.getElementById('npt').textContent=d.title||'Unknown Track';document.getElementById('npa').textContent=d.artist||'Unknown Artist';document.getElementById('st').textContent='AutoDJ';document.getElementById('si').className='status'}}catch(e){}}
upd();setInterval(upd,5000);
</script>
</body>
</html>
HTMLEOF

chown -R www-data:www-data "$WEBROOT"
chmod -R 755 "$WEBROOT"
ok "Player deployed to ${WEBROOT}/index.html"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 4: Install overlay daemon (copy-mode, low CPU)"
echo "════════════════════════════════════════════════════════════"

# ─── Overlay daemon: uses pre-rendered files with -c:v copy ───
cat > /usr/local/bin/autodj-video-overlay <<'OVERLAYEOF'
#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───
LOOPS_DIR="/var/lib/radio/loops"
RENDER_DIR="${LOOPS_DIR}/rendered"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

log(){ echo "[$(date -Is)] $*"; }

get_rendered_loop() {
  # Prefer pre-rendered files (copy-mode, near-zero CPU)
  local loops=()
  if [[ -d "$RENDER_DIR" ]]; then
    while IFS= read -r -d '' f; do loops+=("$f"); done \
      < <(find "$RENDER_DIR" -maxdepth 1 -type f -name "*.mp4" -print0 2>/dev/null)
  fi
  if [[ ${#loops[@]} -gt 0 ]]; then
    echo "copy:${loops[$((RANDOM % ${#loops[@]}))]}"
    return 0
  fi
  # Fallback: raw source files (requires real-time encoding)
  loops=()
  while IFS= read -r -d '' f; do loops+=("$f"); done \
    < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
  if [[ ${#loops[@]} -gt 0 ]]; then
    echo "encode:${loops[$((RANDOM % ${#loops[@]}))]}"
    return 0
  fi
  return 1
}

# Wait for audio publisher on RTMP autodj_audio
log "Waiting for audio publisher on RTMP autodj_audio..."
for i in {1..90}; do
  STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || true)"
  if echo "$STAT" | awk '/<name>autodj_audio<\/name>/,/<\/application>/' | grep -q '<publishing>'; then
    log "Audio publisher detected on autodj_audio"
    break
  fi
  NC=$(echo "$STAT" | awk '/<name>autodj_audio<\/name>/,/<\/application>/' \
       | grep -oP '<nclients>\K[0-9]+' | head -1 || true)
  if [[ "${NC:-0}" -gt 0 ]]; then
    log "Audio clients detected (nclients=$NC)"
    break
  fi
  sleep 2
done

while true; do
  SELECTION=$(get_rendered_loop) || { log "No video loops, waiting..."; sleep 10; continue; }
  MODE="${SELECTION%%:*}"
  LOOP_MP4="${SELECTION#*:}"

  if [[ "$MODE" == "copy" ]]; then
    # ─── COPY MODE: pre-rendered file, video pass-through ───
    # Video is already 1920x1080 30fps H.264 CBR — just remux it
    # CPU usage: ~2% (only AAC audio encoding)
    log "COPY mode: $(basename "$LOOP_MP4") + live audio -> RTMP"
    ffmpeg -hide_banner -loglevel warning \
      -re -stream_loop -1 -i "$LOOP_MP4" \
      -thread_queue_size 1024 -i "$AUDIO_IN" \
      -map 0:v:0 -map 1:a:0 \
      -c:v copy \
      -c:a aac -b:a 128k -ar 44100 -ac 2 \
      -muxdelay 0 -muxpreload 0 -flvflags no_duration_filesize \
      -f flv "$OUT" || true
  else
    # ─── ENCODE MODE: fallback for non-pre-rendered files ───
    # Full real-time encoding (~30% CPU)
    log "ENCODE mode (not pre-rendered): $(basename "$LOOP_MP4")"
    log "  Run 'radio-prerender' to pre-render and reduce CPU usage"
    FPS=30; FRAG=6; GOP=$((FPS*FRAG))
    ffmpeg -hide_banner -loglevel warning \
      -re -stream_loop -1 -i "$LOOP_MP4" \
      -thread_queue_size 1024 -i "$AUDIO_IN" \
      -map 0:v:0 -map 1:a:0 \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
      -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
      -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
      -force_key_frames "expr:gte(t,n_forced*${FRAG})" \
      -b:v 2500k -maxrate 2500k -bufsize 5000k \
      -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
      -c:a aac -b:a 128k -ar 44100 -ac 2 \
      -muxdelay 0 -muxpreload 0 -flvflags no_duration_filesize \
      -f flv "$OUT" || true
  fi

  log "FFmpeg exited, restarting in 3s..."
  sleep 3
done
OVERLAYEOF
chmod +x /usr/local/bin/autodj-video-overlay
ok "Overlay daemon installed (copy-mode + encode fallback)"

# ─── radio-prerender utility ───
cat > /usr/local/bin/radio-prerender <<'PRERENDEREOF'
#!/usr/bin/env bash
set -euo pipefail
# radio-prerender — Pre-render mp4 loops to broadcast spec for -c:v copy playback
# Run after uploading new mp4 files to /var/lib/radio/loops/
# Usage: radio-prerender [--force]

LOOPS_DIR="/var/lib/radio/loops"
RENDER_DIR="${LOOPS_DIR}/rendered"
FPS=30; FRAG=6; GOP=$((FPS*FRAG))
FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

mkdir -p "$RENDER_DIR"
echo "Pre-rendering video loops → ${RENDER_DIR}/"
echo "Target: 1920x1080, ${FPS}fps, H.264 CBR 2500k, keyframe every ${FRAG}s"
echo ""

COUNT=0
while IFS= read -r -d '' src; do
  FNAME="$(basename "$src")"
  RENDERED="${RENDER_DIR}/${FNAME}"
  SRC_MTIME="$(stat -c %Y "$src" 2>/dev/null || echo 0)"
  RND_MTIME="$(stat -c %Y "$RENDERED" 2>/dev/null || echo 0)"

  if [[ "$FORCE" == false && -f "$RENDERED" && "$RND_MTIME" -ge "$SRC_MTIME" ]]; then
    echo "  SKIP  $FNAME (already rendered)"
    COUNT=$((COUNT + 1))
    continue
  fi

  V_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$src" 2>/dev/null || true)"
  if [[ -z "$V_CODEC" ]]; then
    echo "  SKIP  $FNAME (no video track)"
    continue
  fi

  echo "  RENDERING $FNAME ..."
  TMP="${RENDERED}.tmp.mp4"
  if ffmpeg -hide_banner -y \
    -i "$src" \
    -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=${FPS}" \
    -c:v libx264 -preset medium -pix_fmt yuv420p \
    -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${FRAG})" \
    -b:v 2500k -maxrate 2500k -bufsize 5000k \
    -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
    -an -movflags +faststart \
    "$TMP" 2>&1 | tail -3; then
    mv "$TMP" "$RENDERED"
    SIZE_MB=$(( $(stat -c %s "$RENDERED") / 1048576 ))
    echo "  OK    $FNAME → ${SIZE_MB}MB"
    COUNT=$((COUNT + 1))
  else
    rm -f "$TMP"
    echo "  FAIL  $FNAME"
  fi
done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)

# Clean orphans
while IFS= read -r -d '' rnd; do
  FNAME="$(basename "$rnd")"
  [[ ! -f "${LOOPS_DIR}/${FNAME}" ]] && rm -f "$rnd" && echo "  CLEAN orphan: $FNAME"
done < <(find "$RENDER_DIR" -maxdepth 1 -type f -name "*.mp4" -print0 2>/dev/null)

echo ""
echo "Done. ${COUNT} rendered file(s) ready."
echo "Restart overlay to use: systemctl restart autodj-video-overlay"
PRERENDEREOF
chmod +x /usr/local/bin/radio-prerender
ok "radio-prerender utility installed"

# ─── Systemd service ───
cat > /etc/systemd/system/autodj-video-overlay.service <<'EOF'
[Unit]
Description=AutoDJ Video Overlay (pre-rendered loop + live audio to RTMP)
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
KillMode=mixed
KillSignal=SIGINT
TimeoutStopSec=10
SendSIGKILL=yes
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ok "Systemd service updated"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 5: Stop all radio services"
echo "════════════════════════════════════════════════════════════"

for svc in radio-nowplayingd radio-hls-relay radio-switchd autodj-video-overlay liquidsoap-autodj; do
  systemctl stop "$svc" 2>/dev/null && ok "Stopped $svc" || true
done
pkill -f "autodj-video-overlay" 2>/dev/null || true
pkill -f "ffmpeg.*autodj/index" 2>/dev/null || true
sleep 2

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 6: Clean stale HLS state"
echo "════════════════════════════════════════════════════════════"

rm -f /var/lib/radio-hls-relay/state.json
rm -f /var/www/hls/current/seg-*.ts /var/www/hls/current/index.m3u8 2>/dev/null || true
rm -f /var/www/hls/autodj/*.ts /var/www/hls/autodj/*.m3u8 2>/dev/null || true
ok "Stale HLS segments and relay state cleared"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 7: Start services (ordered with health checks)"
echo "════════════════════════════════════════════════════════════"

wait_for() {
  local desc="$1" timeout="$2" check="$3" i=0
  while [[ $i -lt $timeout ]]; do
    if eval "$check" 2>/dev/null; then ok "$desc (${i}s)"; return 0; fi
    sleep 1; i=$((i+1))
  done
  warn "$desc — not ready after ${timeout}s"
  return 1
}

# 7a. Nginx
log "Reloading nginx..."
nginx -t 2>&1 && systemctl reload nginx && ok "nginx reloaded" || { fail "nginx config error"; nginx -t; }

# 7b. Liquidsoap
log "Starting liquidsoap-autodj..."
systemctl start liquidsoap-autodj
sleep 3
if systemctl is-active --quiet liquidsoap-autodj; then
  ok "liquidsoap-autodj running"
else
  fail "Liquidsoap failed!"; journalctl -u liquidsoap-autodj -n 15 --no-pager; exit 1
fi

# 7c. Wait for audio on RTMP
log "Waiting for audio stream on RTMP autodj_audio..."
RTMP_CHK='curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | awk "/<name>autodj_audio<.name>/,/<.application>/" | grep -qE "<nclients>[1-9]|<publishing>"'
wait_for "RTMP autodj_audio active" 30 "$RTMP_CHK" || warn "Audio may still be connecting..."

# 7d. Video overlay
log "Starting autodj-video-overlay..."
systemctl start autodj-video-overlay
sleep 2
if systemctl is-active --quiet autodj-video-overlay; then
  ok "autodj-video-overlay running"
else
  warn "Overlay not started — check logs: journalctl -u autodj-video-overlay -n 20"
fi

# 7e. Wait for HLS segments
log "Waiting for HLS segments from autodj..."
HLS_CHK='ls /var/www/hls/autodj/*.ts 2>/dev/null | head -1 | grep -q .'
wait_for "HLS segments generated" 60 "$HLS_CHK" || {
  fail "No HLS segments after 60s"
  echo "--- overlay log ---"
  journalctl -u autodj-video-overlay -n 15 --no-pager -q 2>/dev/null || true
}

# 7f. Switch daemon
log "Starting radio-switchd..."
systemctl start radio-switchd
sleep 1
ok "radio-switchd started"

# 7g. HLS relay
log "Starting radio-hls-relay..."
systemctl start radio-hls-relay
sleep 2
RELAY_CHK='ls /var/www/hls/current/seg-*.ts 2>/dev/null | head -1 | grep -q .'
wait_for "Relay producing /hls/current/ segments" 15 "$RELAY_CHK" || true

# 7h. Now-playing daemon
log "Starting radio-nowplayingd..."
systemctl start radio-nowplayingd
sleep 2
ok "radio-nowplayingd started"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 8: Verification"
echo "════════════════════════════════════════════════════════════"
echo ""

ALL_OK=true

echo "--- Services ---"
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd; do
  st="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  if [[ "$st" == "active" ]]; then ok "$svc"; else fail "$svc ($st)"; ALL_OK=false; fi
done

echo ""
echo "--- CPU Usage (overlay) ---"
OV_PID="$(pgrep -f 'ffmpeg.*autodj/index' | head -1 || true)"
if [[ -n "$OV_PID" ]]; then
  # Sample CPU over 2 seconds
  OV_CPU="$(ps -p "$OV_PID" -o %cpu= 2>/dev/null | tr -d ' ' || true)"
  OV_CMD="$(ps -p "$OV_PID" -o args= 2>/dev/null || true)"
  if echo "$OV_CMD" | grep -q '\-c:v copy'; then
    ok "Overlay using COPY mode (PID $OV_PID, CPU ${OV_CPU}%)"
  else
    warn "Overlay using ENCODE mode (PID $OV_PID, CPU ${OV_CPU}%)"
    echo "  Run 'radio-prerender' then restart overlay to switch to copy mode"
  fi
else
  warn "No overlay FFmpeg process found yet"
fi

echo ""
echo "--- RTMP Streams ---"
STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || echo '<empty/>')"
for app in autodj_audio autodj; do
  BLK="$(echo "$STAT" | awk "/<name>${app}<\\/name>/,/<\\/application>/")"
  BW=$(echo "$BLK" | grep -oP '<bw_in>\K[0-9]+' | head -1 || true)
  NC=$(echo "$BLK" | grep -oP '<nclients>\K[0-9]+' | head -1 || true)
  if [[ "${NC:-0}" -gt 0 ]]; then
    BW_K=$(( ${BW:-0} / 1024 ))
    ok "rtmp/${app} — ${NC} client(s), ${BW_K} kbps"
  else
    fail "rtmp/${app} — no clients"; ALL_OK=false
  fi
done

echo ""
echo "--- HLS Output ---"
AUTODJ_SEGS=$(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)
CURRENT_SEGS=$(ls /var/www/hls/current/seg-*.ts 2>/dev/null | wc -l)
echo "  AutoDJ segments:  $AUTODJ_SEGS"
echo "  Current segments: $CURRENT_SEGS"

if [[ "$AUTODJ_SEGS" -gt 0 ]]; then
  ok "HLS pipeline producing segments"
  SAMPLE="$(ls -t /var/www/hls/autodj/*.ts 2>/dev/null | head -1)"
  if [[ -n "$SAMPLE" ]]; then
    STREAMS="$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$SAMPLE" 2>/dev/null || true)"
    if echo "$STREAMS" | grep -q "video"; then
      ok "HLS segments contain VIDEO track"
    else
      fail "HLS segments are AUDIO-ONLY — overlay video not reaching HLS!"
      ALL_OK=false
    fi
    echo "$STREAMS" | grep -q "audio" && ok "HLS segments contain AUDIO track" || warn "No audio in HLS"
  fi
else
  fail "No HLS segments"; ALL_OK=false
fi

echo ""
echo "--- Now-Playing API ---"
NP_FILE="$(cat /var/www/radio/data/nowplaying.json 2>/dev/null || echo '{}')"
echo "  File: $NP_FILE"
API="$(curl -sSk -H 'Host: radio.peoplewelike.club' https://127.0.0.1/api/nowplaying 2>/dev/null \
  || curl -sS -H 'Host: radio.peoplewelike.club' -L http://127.0.0.1/api/nowplaying 2>/dev/null \
  || echo 'FAILED')"
echo "  API:  $API"
echo "$API" | grep -q '"mode"' && ok "API responding" || { fail "API not responding"; ALL_OK=false; }

echo ""
echo "--- Player HTML ---"
if [[ -f "${WEBROOT}/index.html" ]] && grep -q 'hls/current' "${WEBROOT}/index.html"; then
  ok "Player HTML deployed with video.js + HLS source"
else
  fail "Player HTML missing or broken"; ALL_OK=false
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if $ALL_OK; then
  echo -e "${GRN}  ALL SYSTEMS GO — Radio with video overlay is live!${NC}"
else
  echo -e "${YLW}  SOME ISSUES — review output above${NC}"
fi
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Test:  https://radio.peoplewelike.club/"
echo "HLS:   https://radio.peoplewelike.club/hls/current/index.m3u8"
echo "API:   https://radio.peoplewelike.club/api/nowplaying"
echo ""
echo "Commands:"
echo "  radio-prerender          Pre-render new mp4 files (after SFTP upload)"
echo "  radio-prerender --force  Force re-render all files"
echo "  radio-ctl status         Check all services"
echo "  radio-ctl restart        Restart all services"
echo ""
