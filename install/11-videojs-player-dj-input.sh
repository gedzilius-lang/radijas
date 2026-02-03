#!/usr/bin/env bash
###############################################################################
# VIDEO.JS PLAYER WITH AUTO DJ / LIVE DJ INPUT SWITCHING
# People We Like Radio Installation - Step 11
#
# This script deploys a Video.js HLS player that seamlessly switches between
# AutoDJ (automated playlists via Liquidsoap) and Live DJ input (RTMP ingest).
#
# Architecture:
#   Browser → /hls/current/index.m3u8 (stable URL, never changes)
#           ↑
#   radio-hls-relay writes monotonic segments + #EXT-X-DISCONTINUITY markers
#           ↑
#   radio-switchd detects live/autodj health → /run/radio/active
#           ↑
#   nginx-rtmp produces /hls/autodj/ and /hls/live/ independently
#
# The player polls /api/nowplaying every 3s and adjusts the UI accordingly.
# Video.js handles #EXT-X-DISCONTINUITY tags natively for seamless playback.
#
# Requirements:
#   - nginx with RTMP module + HLS output (03-configure-nginx.sh)
#   - radio-switchd daemon running (05-create-scripts.sh + 06-create-services.sh)
#   - radio-hls-relay daemon running (05-create-scripts.sh + 06-create-services.sh)
#   - /api/nowplaying endpoint returning JSON with "mode" field
#
# Run as root:
#   bash install/11-videojs-player-dj-input.sh
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Video.js Player - AutoDJ / Live DJ Input"
echo "=============================================="

# ─────────────────────────────────────────────────
# 0. Pre-checks
# ─────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

WEB_ROOT="/var/www/radio.peoplewelike.club"
mkdir -p "$WEB_ROOT"

# ─────────────────────────────────────────────────
# 1. Backup existing player
# ─────────────────────────────────────────────────
if [[ -f "$WEB_ROOT/index.html" ]]; then
    BACKUP="$WEB_ROOT/index.html.backup.$(date +%s)"
    cp "$WEB_ROOT/index.html" "$BACKUP"
    echo "[0/3] Backed up existing player → $(basename "$BACKUP")"
fi

# ─────────────────────────────────────────────────
# 1. Create the player HTML
# ─────────────────────────────────────────────────
echo "[1/3] Creating Video.js player with DJ input switching..."
cat > "$WEB_ROOT/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#0d0a1a">
    <meta name="format-detection" content="telephone=no">
    <title>People We Like Radio</title>
    <link rel="apple-touch-icon" href="/poster.jpg">
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root {
            --bg-dark:#0d0a1a;--bg-card:#1a1329;--purple:#6b46c1;--purple-light:#9f7aea;
            --purple-glow:rgba(107,70,193,0.4);--red-live:#e53e3e;--red-glow:rgba(229,62,62,0.6);
            --text:#e2e8f0;--text-muted:#a0aec0;--text-dim:#718096;
            --safe-top:env(safe-area-inset-top,0px);--safe-right:env(safe-area-inset-right,0px);
            --safe-bottom:env(safe-area-inset-bottom,0px);--safe-left:env(safe-area-inset-left,0px);
        }
        *,*::before,*::after{margin:0;padding:0;box-sizing:border-box}
        html{-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;text-size-adjust:100%;overflow-x:hidden;height:100%}
        body{
            font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Oxygen,Ubuntu,Cantarell,sans-serif;
            background:var(--bg-dark);color:var(--text);min-height:100%;min-height:100dvh;
            overflow-x:hidden;-webkit-tap-highlight-color:transparent;-webkit-touch-callout:none;
            padding:var(--safe-top) var(--safe-right) var(--safe-bottom) var(--safe-left);
        }
        .bg-glow{position:fixed;inset:0;z-index:-1;pointer-events:none;background:radial-gradient(ellipse at 20% 80%,rgba(107,70,193,.12) 0%,transparent 50%),radial-gradient(ellipse at 80% 20%,rgba(159,122,234,.08) 0%,transparent 50%);transition:background 1s ease}
        body.live-mode .bg-glow{background:radial-gradient(ellipse at 20% 80%,rgba(229,62,62,.10) 0%,transparent 50%),radial-gradient(ellipse at 80% 20%,rgba(229,62,62,.06) 0%,transparent 50%)}
        .page{width:100%;max-width:1060px;margin:0 auto;padding:clamp(8px,2vw,20px);display:flex;flex-direction:column;min-height:100vh;min-height:100dvh}
        header{text-align:center;padding:clamp(12px,3vw,30px) clamp(8px,2vw,20px) clamp(8px,2vw,20px)}
        .logo{font-size:clamp(1.4em,5vw,2.2em);font-weight:700;background:linear-gradient(135deg,var(--purple-light),var(--purple));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;line-height:1.2}
        body.live-mode .logo{background:linear-gradient(135deg,#fc8181,var(--red-live));-webkit-background-clip:text;background-clip:text}
        .tagline{color:var(--text-dim);font-size:clamp(0.65em,2vw,0.85em);letter-spacing:clamp(1px,0.5vw,3px);text-transform:uppercase;margin-top:2px}
        .source-strip{display:flex;justify-content:center;gap:clamp(6px,1.5vw,12px);margin-bottom:clamp(8px,2vw,18px)}
        .source-option{display:flex;align-items:center;gap:clamp(4px,1vw,8px);padding:clamp(6px,1.2vw,8px) clamp(12px,2.5vw,20px);border-radius:24px;font-size:clamp(0.65em,1.8vw,0.8em);font-weight:600;text-transform:uppercase;letter-spacing:1px;border:1.5px solid transparent;opacity:.45;transition:all .4s ease;white-space:nowrap}
        .source-option.active{opacity:1}
        .source-option.program{border-color:rgba(107,70,193,.4);background:rgba(107,70,193,.12);color:var(--purple-light)}
        .source-option.program.active{border-color:var(--purple-light);background:rgba(107,70,193,.2);box-shadow:0 0 18px var(--purple-glow)}
        .source-option.live{border-color:rgba(229,62,62,.4);background:rgba(229,62,62,.12);color:var(--red-live)}
        .source-option.live.active{border-color:var(--red-live);background:rgba(229,62,62,.2);box-shadow:0 0 18px var(--red-glow);animation:liveGlow 1.6s ease-in-out infinite}
        .source-dot{width:clamp(6px,1.2vw,8px);height:clamp(6px,1.2vw,8px);border-radius:50%;background:currentColor;flex-shrink:0}
        .source-option.live.active .source-dot{animation:blink 1s infinite}
        @keyframes liveGlow{0%,100%{box-shadow:0 0 12px var(--red-glow)}50%{box-shadow:0 0 28px var(--red-glow),0 0 48px rgba(229,62,62,.25)}}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:.25}}
        .player-card{background:var(--bg-card);border-radius:clamp(8px,2vw,16px);overflow:hidden;box-shadow:0 10px 40px rgba(0,0,0,.5);border:1px solid rgba(107,70,193,.2);transition:border-color .5s,box-shadow .5s}
        .player-card.live{border-color:rgba(229,62,62,.35);box-shadow:0 10px 40px rgba(0,0,0,.5),0 0 40px var(--red-glow)}
        .video-area{position:relative;background:#000;width:100%}
        .video-ratio{position:relative;width:100%;padding-top:56.25%}
        .video-ratio .video-js{position:absolute;top:0;left:0;width:100%;height:100%}
        .switch-overlay{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;flex-direction:column;gap:clamp(8px,2vw,14px);background:rgba(13,10,26,.85);opacity:0;pointer-events:none;transition:opacity .4s ease;z-index:20}
        .switch-overlay.visible{opacity:1}
        .switch-overlay .spinner{width:clamp(28px,6vw,40px);height:clamp(28px,6vw,40px);border:3px solid rgba(255,255,255,.15);border-top-color:var(--purple-light);border-radius:50%;animation:spin .8s linear infinite}
        body.live-mode .switch-overlay .spinner{border-top-color:var(--red-live)}
        .switch-overlay span{font-size:clamp(0.75em,2vw,0.9em);color:var(--text-muted)}
        @keyframes spin{to{transform:rotate(360deg)}}
        .now-playing{padding:clamp(10px,2.5vw,18px) clamp(12px,3vw,22px);background:rgba(0,0,0,.3);display:flex;align-items:center;gap:clamp(10px,2vw,16px)}
        .np-icon{width:clamp(36px,8vw,48px);height:clamp(36px,8vw,48px);background:linear-gradient(135deg,var(--purple),var(--purple-light));border-radius:clamp(8px,1.5vw,12px);display:flex;align-items:center;justify-content:center;font-size:clamp(16px,4vw,22px);flex-shrink:0}
        body.live-mode .np-icon{background:linear-gradient(135deg,#c53030,var(--red-live))}
        .np-info{flex:1;min-width:0;overflow:hidden}
        .np-label{font-size:clamp(0.55em,1.5vw,0.7em);text-transform:uppercase;letter-spacing:clamp(1px,0.3vw,2px);color:var(--text-dim);margin-bottom:2px}
        .np-title{font-size:clamp(0.85em,2.5vw,1.1em);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .np-artist{font-size:clamp(0.75em,2vw,0.9em);color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        footer{text-align:center;padding:clamp(16px,3vw,30px) clamp(8px,2vw,20px);color:var(--text-dim);font-size:clamp(0.7em,1.8vw,0.82em);margin-top:auto}
        footer a{color:var(--purple-light);text-decoration:none}
        .video-js .vjs-big-play-button{background:var(--purple);border:none;border-radius:50%;width:clamp(50px,12vw,76px);height:clamp(50px,12vw,76px);line-height:clamp(50px,12vw,76px);top:50%;left:50%;transform:translate(-50%,-50%);margin:0}
        .video-js:hover .vjs-big-play-button{background:var(--purple-light)}
        body.live-mode .video-js .vjs-big-play-button{background:var(--red-live)}
        body.live-mode .video-js:hover .vjs-big-play-button{background:#fc8181}
        .video-js .vjs-control-bar{background:rgba(13,10,26,.92);font-size:clamp(10px,2.2vw,14px)}
        .video-js .vjs-play-progress,.video-js .vjs-volume-level{background:var(--purple)}
        body.live-mode .video-js .vjs-play-progress,body.live-mode .video-js .vjs-volume-level{background:var(--red-live)}
        .video-js .vjs-control{min-width:44px;min-height:44px}
        .video-js .vjs-progress-control{min-height:44px}
        .video-js .vjs-slider{touch-action:none}
        @media(max-width:374px){.page{padding:4px}header{padding:8px 4px 6px}.source-option{padding:5px 10px;font-size:0.62em;letter-spacing:0.5px}.now-playing{padding:8px 10px;gap:8px}.player-card{border-radius:6px}}
        @media(min-width:375px) and (max-width:413px){.page{padding:6px}header{padding:10px 8px 8px}}
        @media(min-width:414px) and (max-width:639px){.page{padding:8px}header{padding:14px 10px 10px}}
        @media(min-width:640px) and (max-width:767px){.page{padding:12px}}
        @media(min-width:768px) and (max-width:1023px){.page{padding:16px}}
        @media(min-width:1024px){.player-card:hover{box-shadow:0 25px 70px rgba(0,0,0,.6),0 0 40px var(--purple-glow)}}
        @media(orientation:landscape) and (max-height:500px){header{padding:4px 8px 2px}.logo{font-size:1.1em}.tagline{display:none}.source-strip{margin-bottom:4px;gap:6px}.source-option{padding:3px 10px;font-size:0.65em}.now-playing{padding:6px 10px;gap:8px}.np-icon{width:28px;height:28px;font-size:14px;border-radius:6px}.np-label{display:none}footer{padding:6px;font-size:0.65em}}
        @supports(-webkit-touch-callout:none){body{min-height:-webkit-fill-available}.page{min-height:-webkit-fill-available}}
    </style>
</head>
<body>
    <div class="bg-glow"></div>
    <div class="page">
        <header>
            <div class="logo">People We Like</div>
            <div class="tagline">Radio</div>
        </header>
        <div class="source-strip">
            <div class="source-option program active" id="src-program"><span class="source-dot"></span>Program</div>
            <div class="source-option live" id="src-live"><span class="source-dot"></span>Live</div>
        </div>
        <div class="player-card" id="player-card">
            <div class="video-area">
                <div class="video-ratio">
                    <video id="radio-player" class="video-js vjs-big-play-centered" controls preload="auto" playsinline webkit-playsinline poster="/poster.jpg">
                        <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                        <p class="vjs-no-js">Enable JavaScript and use a modern browser to watch this stream.</p>
                    </video>
                </div>
                <div class="switch-overlay" id="switch-overlay"><div class="spinner"></div><span id="switch-text">Switching source...</span></div>
            </div>
            <div class="now-playing">
                <div class="np-icon" id="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Connecting...</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
            </div>
        </div>
        <footer>&copy; 2025 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></footer>
    </div>
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
    (function(){
        'use strict';
        var player=videojs('radio-player',{liveui:true,liveTracker:{trackingThreshold:0,liveTolerance:15},html5:{vhs:{overrideNative:true,smoothQualityChange:true,allowSeeksWithinUnsafeLiveWindow:true,handlePartialData:true,experimentalBufferBasedABR:true},nativeAudioTracks:false,nativeVideoTracks:false},controlBar:{playToggle:true,volumePanel:{inline:true},pictureInPictureToggle:true,fullscreenToggle:true,currentTimeDisplay:false,timeDivider:false,durationDisplay:false,remainingTimeDisplay:false},controls:true,autoplay:false,preload:'auto',playsinline:true,errorDisplay:false,responsive:true,fluid:false});
        var npLabel=document.getElementById('np-label'),npTitle=document.getElementById('np-title'),npArtist=document.getElementById('np-artist');
        var srcProgram=document.getElementById('src-program'),srcLive=document.getElementById('src-live');
        var playerCard=document.getElementById('player-card'),switchOverlay=document.getElementById('switch-overlay'),switchText=document.getElementById('switch-text');
        var currentMode='autodj',switchInProgress=false,errorRecovering=false,POLL_INTERVAL=3000,HLS_URL='/hls/current/index.m3u8';
        function setMode(mode){var prev=currentMode;currentMode=mode;var isLive=(mode==='live');document.body.classList.toggle('live-mode',isLive);srcProgram.classList.toggle('active',!isLive);srcLive.classList.toggle('active',isLive);playerCard.classList.toggle('live',isLive);if(prev!==mode&&prev!==null&&!player.paused()){showSwitchOverlay(isLive?'Switching to Live...':'Switching to Program...')}}
        function showSwitchOverlay(msg){if(switchInProgress)return;switchInProgress=true;switchText.textContent=msg;switchOverlay.classList.add('visible');setTimeout(function(){switchOverlay.classList.remove('visible');switchInProgress=false},3000)}
        function updateNowPlaying(){fetch('/api/nowplaying?'+Date.now()).then(function(r){return r.json()}).then(function(data){var mode=data.mode==='live'?'live':'autodj';setMode(mode);if(mode==='live'){npLabel.textContent='LIVE BROADCAST';npTitle.textContent=data.title||'LIVE SHOW';npArtist.textContent=data.artist||''}else{npLabel.textContent='Now Playing';npTitle.textContent=data.title||'Unknown Track';npArtist.textContent=data.artist||'Unknown Artist'}}).catch(function(){})}
        updateNowPlaying();setInterval(updateNowPlaying,POLL_INTERVAL);
        var ERROR_RETRY_DELAY=3000,MAX_RETRIES=5,retryCount=0;
        player.on('error',function(){if(errorRecovering)return;errorRecovering=true;var err=player.error();console.warn('[radio] error:',err&&err.message);if(retryCount>=MAX_RETRIES){npTitle.textContent='Stream unavailable - click Play to retry';errorRecovering=false;retryCount=0;return}retryCount++;setTimeout(function(){player.src({src:HLS_URL,type:'application/x-mpegURL'});player.load();player.play().catch(function(){});errorRecovering=false},ERROR_RETRY_DELAY)});
        player.on('playing',function(){retryCount=0});
        player.on('playing',function(){try{var lt=player.liveTracker;if(lt&&lt.isLive()&&lt.behindLiveEdge()){lt.seekToLiveEdge()}}catch(e){}});
        var resizeTimer;function onResize(){clearTimeout(resizeTimer);resizeTimer=setTimeout(function(){player.dimensions(undefined,undefined)},200)}
        window.addEventListener('orientationchange',onResize);window.addEventListener('resize',onResize);
        var unlocked=false;document.addEventListener('touchstart',function iosUnlock(){if(unlocked)return;unlocked=true;if(player.paused()){var p=player.play();if(p&&p.catch){p.catch(function(){})}}document.removeEventListener('touchstart',iosUnlock)},{once:true,passive:true});
    })();
    </script>
</body>
</html>
HTMLEOF
echo "    Created $WEB_ROOT/index.html"

# ─────────────────────────────────────────────────
# 2. Create poster image (dark purple theme)
# ─────────────────────────────────────────────────
echo "[2/3] Creating poster image..."
cat > "$WEB_ROOT/poster.svg" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%"   style="stop-color:#0d0a1a"/>
      <stop offset="50%"  style="stop-color:#1a1329"/>
      <stop offset="100%" style="stop-color:#0d0a1a"/>
    </linearGradient>
    <linearGradient id="txt" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%"   style="stop-color:#9f7aea"/>
      <stop offset="100%" style="stop-color:#6b46c1"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <circle cx="200"  cy="800" r="300" fill="#6b46c1" opacity="0.1"/>
  <circle cx="1700" cy="200" r="250" fill="#9f7aea" opacity="0.08"/>
  <text x="960" y="480" text-anchor="middle" font-family="Arial,sans-serif"
        font-size="72" font-weight="bold" fill="url(#txt)">People We Like</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial,sans-serif"
        font-size="36" fill="#a0aec0" letter-spacing="8">RADIO</text>
  <text x="960" y="700" text-anchor="middle" font-family="Arial,sans-serif"
        font-size="24" fill="#718096">Loading stream...</text>
</svg>
SVGEOF

# Convert SVG to JPG if ffmpeg is available
if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i "$WEB_ROOT/poster.svg" \
           -vf "scale=1920:1080" \
           "$WEB_ROOT/poster.jpg" 2>/dev/null || true
    echo "    Created poster.jpg"
else
    echo "    ffmpeg not found — poster.svg created (JPG conversion skipped)"
fi

# ─────────────────────────────────────────────────
# 3. Set ownership & permissions
# ─────────────────────────────────────────────────
echo "[3/3] Setting permissions..."
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"

echo ""
echo "=============================================="
echo "  Player Deployed"
echo "=============================================="
echo ""
echo "Features:"
echo "  - Video.js 8 HLS player on /hls/current/index.m3u8"
echo "  - Program / Live source strip indicator"
echo "  - All playback via Video.js controls (play, stop, volume, PiP, fullscreen)"
echo "  - Seamless switching via HLS discontinuity tags"
echo "  - Automatic error recovery (up to 5 retries)"
echo "  - Live edge seeking after source switch"
echo "  - Transition overlay animation during switch"
echo "  - /api/nowplaying polling every 3 seconds"
echo "  - Full theme shift (purple Program / red Live)"
echo "  - Fully responsive: iPhone SE to 4K desktop"
echo "  - iOS Safari: playsinline, safe-area, audio unlock"
echo "  - Landscape phone mode: compact UI, larger video"
echo "  - Touch-friendly: 44px min targets on control bar"
echo "  - Fluid typography with clamp() at every breakpoint"
echo ""
echo "Player URL: https://radio.peoplewelike.club/"
echo ""
echo "Backend services required:"
echo "  systemctl status radio-switchd      # writes /run/radio/active"
echo "  systemctl status radio-hls-relay    # writes /hls/current/"
echo "  systemctl status liquidsoap-autodj  # AutoDJ audio"
echo "  systemctl status autodj-video-overlay  # FFmpeg video loop"
echo ""
