#!/usr/bin/env bash
###############################################################################
# hotfix-radio.sh — Fix video overlay, deploy player, restart services
# People We Like Radio
# Run as root:  bash hotfix-radio.sh
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GRN}OK${NC}  $*"; }
warn() { echo -e "  ${YLW}WARN${NC} $*"; }
fail() { echo -e "  ${RED}FAIL${NC} $*"; }

if [[ $EUID -ne 0 ]]; then fail "Must run as root"; exit 1; fi

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 1: Validate video loop files"
echo "════════════════════════════════════════════════════════════"

LOOPS_DIR="/var/lib/radio/loops"
mkdir -p "$LOOPS_DIR"
LOOP_COUNT=$(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) 2>/dev/null | wc -l)

if [[ "$LOOP_COUNT" -eq 0 ]]; then
  fail "No .mp4 files in $LOOPS_DIR"
  echo "  Upload at least one .mp4 file via SFTP to: $LOOPS_DIR"
  echo "  Requirements: H.264 video, any resolution (will be scaled to 1080p)"
else
  ok "Found $LOOP_COUNT video loop(s)"
  # Validate each mp4
  while IFS= read -r -d '' mp4; do
    FNAME="$(basename "$mp4")"
    FSIZE="$(stat -c %s "$mp4" 2>/dev/null || echo 0)"
    FSIZE_MB=$(( FSIZE / 1048576 ))

    V_CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$mp4" 2>/dev/null || true)"
    V_RES="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$mp4" 2>/dev/null || true)"
    V_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$mp4" 2>/dev/null || true)"

    if [[ -z "$V_CODEC" ]]; then
      fail "$FNAME (${FSIZE_MB}MB) — NO VIDEO TRACK! This file cannot be used as overlay."
      echo "       The file may be corrupted or is not a valid video."
      echo "       Re-upload a proper H.264 .mp4 file."
    else
      V_DUR_S="${V_DUR%%.*}"
      ok "$FNAME: ${FSIZE_MB}MB, codec=${V_CODEC}, res=${V_RES}, dur=${V_DUR_S:-?}s"
      if [[ "${FSIZE}" -lt 500000 ]]; then
        warn "  File is very small (<500KB). Ensure it's a real video, not a thumbnail."
      fi
    fi
  done < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
fi

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 2: Deploy player HTML"
echo "════════════════════════════════════════════════════════════"

WEBROOT="/var/www/radio.peoplewelike.club"
mkdir -p "$WEBROOT"

# Always redeploy — ensures video.js player is present and up to date
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
log "STEP 3: Update overlay daemon & systemd services"
echo "════════════════════════════════════════════════════════════"

# Update the overlay daemon script on disk
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
  while IFS= read -r -d '' f; do loops+=("$f"); done \
    < <(find "$LOOPS_DIR" -maxdepth 1 -type f \( -name "*.mp4" -o -name "*.MP4" \) -print0 2>/dev/null)
  [[ ${#loops[@]} -eq 0 ]] && return 1
  echo "${loops[$((RANDOM % ${#loops[@]}))]}"
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
    log "Audio clients detected on autodj_audio (nclients=$NC)"
    break
  fi
  sleep 2
done

while true; do
  LOOP_MP4=$(get_random_loop) || { log "No video loops in $LOOPS_DIR, waiting..."; sleep 10; continue; }
  log "Overlay: $(basename "$LOOP_MP4") + audio -> RTMP autodj"

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
ok "Updated /usr/local/bin/autodj-video-overlay"

# Update overlay systemd service with KillMode=mixed for clean FFmpeg stops
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
KillMode=mixed
KillSignal=SIGINT
TimeoutStopSec=10
SendSIGKILL=yes
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ok "Systemd services updated (KillMode=mixed for clean overlay stops)"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 4: Stop all radio services"
echo "════════════════════════════════════════════════════════════"

for svc in radio-nowplayingd radio-hls-relay radio-switchd autodj-video-overlay liquidsoap-autodj; do
  systemctl stop "$svc" 2>/dev/null && ok "Stopped $svc" || true
done
# Kill any leftover FFmpeg overlay processes
pkill -f "autodj-video-overlay" 2>/dev/null || true
pkill -f "ffmpeg.*autodj/index" 2>/dev/null || true
sleep 2

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 5: Clean stale HLS state"
echo "════════════════════════════════════════════════════════════"

rm -f /var/lib/radio-hls-relay/state.json
rm -f /var/www/hls/current/seg-*.ts /var/www/hls/current/index.m3u8 2>/dev/null || true
rm -f /var/www/hls/autodj/*.ts /var/www/hls/autodj/*.m3u8 2>/dev/null || true
ok "Stale HLS segments and relay state cleared"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 6: Start services (ordered with health checks)"
echo "════════════════════════════════════════════════════════════"

# Helper: wait for condition
wait_for() {
  local desc="$1" timeout="$2" check="$3" i=0
  while [[ $i -lt $timeout ]]; do
    if eval "$check" 2>/dev/null; then ok "$desc (${i}s)"; return 0; fi
    sleep 1; i=$((i+1))
  done
  warn "$desc — not ready after ${timeout}s"
  return 1
}

# 6a. Nginx
log "Reloading nginx..."
nginx -t 2>&1 && systemctl reload nginx && ok "nginx reloaded" || { fail "nginx config error"; nginx -t; }

# 6b. Liquidsoap
log "Starting liquidsoap-autodj..."
systemctl start liquidsoap-autodj
sleep 3
if systemctl is-active --quiet liquidsoap-autodj; then
  ok "liquidsoap-autodj running"
else
  fail "Liquidsoap failed!"; journalctl -u liquidsoap-autodj -n 15 --no-pager; exit 1
fi

# 6c. Wait for audio on RTMP
log "Waiting for audio stream on RTMP autodj_audio..."
RTMP_CHK='curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null | awk "/<name>autodj_audio<.name>/,/<.application>/" | grep -qE "<nclients>[1-9]|<publishing>"'
wait_for "RTMP autodj_audio active" 30 "$RTMP_CHK" || warn "Audio may still be connecting..."

# 6d. Video overlay
log "Starting autodj-video-overlay..."
systemctl start autodj-video-overlay
sleep 2
if systemctl is-active --quiet autodj-video-overlay; then
  ok "autodj-video-overlay running"
else
  warn "Overlay not started — check loop.mp4 files"
fi

# 6e. Wait for HLS segments (proves video overlay → nginx-rtmp → HLS works)
log "Waiting for HLS segments from autodj..."
HLS_CHK='ls /var/www/hls/autodj/*.ts 2>/dev/null | head -1 | grep -q .'
wait_for "HLS segments generated" 60 "$HLS_CHK" || {
  fail "No HLS segments after 60s"
  echo "--- overlay log ---"
  journalctl -u autodj-video-overlay -n 15 --no-pager -q 2>/dev/null || true
}

# 6f. Switch daemon
log "Starting radio-switchd..."
systemctl start radio-switchd
sleep 1
ok "radio-switchd started"

# 6g. HLS relay
log "Starting radio-hls-relay..."
systemctl start radio-hls-relay
sleep 2
RELAY_CHK='ls /var/www/hls/current/seg-*.ts 2>/dev/null | head -1 | grep -q .'
wait_for "Relay producing /hls/current/ segments" 15 "$RELAY_CHK" || true

# 6h. Now-playing daemon
log "Starting radio-nowplayingd..."
systemctl start radio-nowplayingd
sleep 2
ok "radio-nowplayingd started"

echo ""
echo "════════════════════════════════════════════════════════════"
log "STEP 7: Verification"
echo "════════════════════════════════════════════════════════════"
echo ""

ALL_OK=true

echo "--- Services ---"
for svc in nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd; do
  st="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
  if [[ "$st" == "active" ]]; then ok "$svc"; else fail "$svc ($st)"; ALL_OK=false; fi
done

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

# Critical check: do HLS segments contain VIDEO?
if [[ "$AUTODJ_SEGS" -gt 0 ]]; then
  ok "HLS pipeline producing segments"
  SAMPLE="$(ls -t /var/www/hls/autodj/*.ts 2>/dev/null | head -1)"
  if [[ -n "$SAMPLE" ]]; then
    STREAMS="$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$SAMPLE" 2>/dev/null || true)"
    if echo "$STREAMS" | grep -q "video"; then
      ok "HLS segments contain VIDEO track"
    else
      fail "HLS segments are AUDIO-ONLY — overlay video not reaching HLS!"
      echo "  Detected streams: $STREAMS"
      ALL_OK=false
    fi
    if echo "$STREAMS" | grep -q "audio"; then
      ok "HLS segments contain AUDIO track"
    else
      warn "HLS segments have no audio track"
    fi
  fi
else
  fail "No HLS segments"; ALL_OK=false
fi

echo ""
echo "--- Now-Playing API ---"
NP_FILE="$(cat /var/www/radio/data/nowplaying.json 2>/dev/null || echo '{}')"
echo "  File: $NP_FILE"
# Use HTTPS (certbot redirects HTTP→HTTPS, so plain HTTP returns 301)
API="$(curl -sSk -H 'Host: radio.peoplewelike.club' https://127.0.0.1/api/nowplaying 2>/dev/null \
  || curl -sS -H 'Host: radio.peoplewelike.club' -L http://127.0.0.1/api/nowplaying 2>/dev/null \
  || echo 'FAILED')"
echo "  API:  $API"
if echo "$API" | grep -q '"mode"'; then ok "API responding"; else fail "API not responding"; ALL_OK=false; fi

echo ""
echo "--- Player HTML ---"
if [[ -f "${WEBROOT}/index.html" ]]; then
  if grep -q 'video-js' "${WEBROOT}/index.html" && grep -q 'hls/current' "${WEBROOT}/index.html"; then
    ok "Player HTML deployed with video.js + HLS source"
  else
    warn "Player HTML exists but may not have video support"
  fi
else
  fail "No index.html at ${WEBROOT}"; ALL_OK=false
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
echo "Test in browser:  https://radio.peoplewelike.club/"
echo "HLS direct:       https://radio.peoplewelike.club/hls/current/index.m3u8"
echo "API check:        https://radio.peoplewelike.club/api/nowplaying"
echo ""
