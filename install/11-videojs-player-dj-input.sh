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
    <meta name="viewport" content="width=device-width,initial-scale=1.0,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#050505">
    <title>People We Like Radio</title>
    <link rel="apple-touch-icon" href="/poster.jpg">
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root{
            --black:#050505;--card:#0c0c0c;--border:#1a1a1a;
            --blue:#2563eb;--blue-dim:rgba(37,99,235,.12);
            --purple:#7c3aed;--purple-dim:rgba(124,58,237,.10);
            --red:#ef4444;--red-dim:rgba(239,68,68,.12);--red-glow:rgba(239,68,68,.35);
            --text:#d4d4d4;--text-mid:#737373;--text-dim:#404040;
            --safe-t:env(safe-area-inset-top,0px);--safe-r:env(safe-area-inset-right,0px);
            --safe-b:env(safe-area-inset-bottom,0px);--safe-l:env(safe-area-inset-left,0px);
        }
        *{margin:0;padding:0;box-sizing:border-box}
        html{height:100%;-webkit-text-size-adjust:100%}
        body{
            font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
            background:var(--black);color:var(--text);min-height:100dvh;
            -webkit-tap-highlight-color:transparent;
            padding:var(--safe-t) var(--safe-r) var(--safe-b) var(--safe-l);
        }
        .page{max-width:960px;margin:0 auto;padding:clamp(6px,2vw,24px);min-height:100dvh;display:flex;flex-direction:column}
        header{text-align:center;padding:clamp(14px,4vw,36px) 0 clamp(8px,2vw,14px)}
        .logo{font-size:clamp(1.2em,4.5vw,1.9em);font-weight:700;letter-spacing:-.03em;color:var(--text)}
        .logo span{color:var(--blue)}
        body.live-mode .logo span{color:var(--red)}
        .tagline{font-size:clamp(.58em,1.6vw,.72em);text-transform:uppercase;letter-spacing:clamp(3px,1vw,8px);color:var(--text-dim);margin-top:3px}
        .strip{display:flex;justify-content:center;gap:clamp(8px,2vw,14px);margin-bottom:clamp(8px,2vw,16px)}
        .pill{display:flex;align-items:center;gap:5px;padding:clamp(4px,.8vw,6px) clamp(12px,2.5vw,20px);border-radius:16px;font-size:clamp(.6em,1.5vw,.72em);font-weight:600;text-transform:uppercase;letter-spacing:1.5px;border:1px solid transparent;opacity:.3;transition:opacity .3s,border-color .3s,box-shadow .3s}
        .pill.active{opacity:1}
        .pill.program{border-color:var(--blue);color:var(--blue)}
        .pill.program.active{background:var(--blue-dim)}
        .pill.live{border-color:rgba(239,68,68,.35);color:var(--red)}
        .pill.live.active{border-color:var(--red);background:var(--red-dim);box-shadow:0 0 20px var(--red-glow);animation:pulse 2s ease-in-out infinite}
        .dot{width:5px;height:5px;border-radius:50%;background:currentColor}
        .pill.live.active .dot{animation:blink 1s infinite}
        @keyframes pulse{0%,100%{box-shadow:0 0 10px rgba(239,68,68,.15)}50%{box-shadow:0 0 24px var(--red-glow)}}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:.15}}
        .card{background:var(--card);border:1px solid var(--border);border-radius:clamp(4px,1vw,10px);overflow:hidden;transition:border-color .4s,box-shadow .4s}
        .card.live{border-color:rgba(239,68,68,.2);box-shadow:0 0 30px rgba(239,68,68,.06)}
        .video-wrap{background:#000;width:100%;position:relative}
        .switch-overlay{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;flex-direction:column;gap:10px;background:rgba(0,0,0,.88);opacity:0;pointer-events:none;transition:opacity .3s;z-index:20}
        .switch-overlay.visible{opacity:1}
        .switch-overlay .spin{width:28px;height:28px;border:2px solid rgba(255,255,255,.08);border-top-color:var(--blue);border-radius:50%;animation:rot .6s linear infinite}
        body.live-mode .switch-overlay .spin{border-top-color:var(--red)}
        .switch-overlay span{font-size:.75em;color:var(--text-mid);letter-spacing:1px;text-transform:uppercase}
        @keyframes rot{to{transform:rotate(360deg)}}
        .np{padding:clamp(8px,2vw,14px) clamp(10px,2.5vw,18px);display:flex;align-items:center;gap:clamp(8px,2vw,12px);border-top:1px solid var(--border)}
        .np-icon{width:clamp(32px,7vw,40px);height:clamp(32px,7vw,40px);background:var(--blue);border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:clamp(13px,3vw,16px);flex-shrink:0;color:#fff}
        body.live-mode .np-icon{background:var(--red)}
        .np-info{flex:1;min-width:0;overflow:hidden}
        .np-label{font-size:clamp(.5em,1.2vw,.6em);text-transform:uppercase;letter-spacing:2px;color:var(--text-dim);margin-bottom:1px}
        .np-title{font-size:clamp(.8em,2vw,.95em);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .np-artist{font-size:clamp(.68em,1.6vw,.8em);color:var(--text-mid);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        footer{text-align:center;padding:clamp(16px,4vw,32px) 0;color:var(--text-dim);font-size:clamp(.6em,1.4vw,.7em);margin-top:auto;letter-spacing:.5px}
        footer a{color:var(--blue);text-decoration:none}
        body.live-mode footer a{color:var(--red)}
        .video-js{width:100%;background:#000}
        .video-js .vjs-big-play-button{background:var(--blue);border:none;border-radius:50%;width:clamp(44px,10vw,64px);height:clamp(44px,10vw,64px);line-height:clamp(44px,10vw,64px);top:50%;left:50%;transform:translate(-50%,-50%);margin:0;transition:background .2s}
        .video-js:hover .vjs-big-play-button{background:var(--purple)}
        body.live-mode .video-js .vjs-big-play-button{background:var(--red)}
        body.live-mode .video-js:hover .vjs-big-play-button{background:#f87171}
        .video-js .vjs-control-bar{background:rgba(0,0,0,.92);font-size:clamp(10px,2vw,13px)}
        .video-js .vjs-play-progress,.video-js .vjs-volume-level{background:var(--blue)}
        body.live-mode .video-js .vjs-play-progress,body.live-mode .video-js .vjs-volume-level{background:var(--red)}
        .video-js .vjs-control{min-width:40px;min-height:40px}
        .video-js .vjs-slider{touch-action:none}
        .video-js .vjs-picture-in-picture-control,.video-js .vjs-fullscreen-control{order:10}
        @media(max-width:374px){.page{padding:4px}.card{border-radius:3px}.np{padding:6px 8px;gap:6px}.np-icon{width:28px;height:28px;border-radius:4px;font-size:12px}}
        @media(orientation:landscape) and (max-height:500px){header{padding:2px 0 1px}.logo{font-size:1em}.tagline{display:none}.strip{margin-bottom:3px}.pill{padding:2px 10px;font-size:.58em}.np{padding:4px 8px;gap:6px}.np-icon{width:24px;height:24px;font-size:11px;border-radius:3px}.np-label{display:none}footer{padding:3px;font-size:.55em}}
        @media(min-width:1024px){.card:hover{box-shadow:0 16px 48px rgba(0,0,0,.7),0 0 1px rgba(37,99,235,.3)}}
        @supports(-webkit-touch-callout:none){body{min-height:-webkit-fill-available}}
    </style>
</head>
<body>
    <div class="page">
        <header>
            <div class="logo">People We <span>Like</span></div>
            <div class="tagline">Radio</div>
        </header>
        <div class="strip">
            <div class="pill program active" id="src-program"><span class="dot"></span>Program</div>
            <div class="pill live" id="src-live"><span class="dot"></span>Live</div>
        </div>
        <div class="card" id="card">
            <div class="video-wrap">
                <video id="radio-player" class="video-js vjs-big-play-centered" controls preload="auto" playsinline webkit-playsinline poster="/poster.jpg">
                    <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                </video>
                <div class="switch-overlay" id="switch-overlay"><div class="spin"></div><span id="switch-text">Switching...</span></div>
            </div>
            <div class="np">
                <div class="np-icon" id="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Connecting...</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
            </div>
        </div>
        <footer>&copy; 2025 <a href="https://peoplewelike.club">People We Like</a></footer>
    </div>
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
    (function(){
        'use strict';
        var player=videojs('radio-player',{
            liveui:true,
            liveTracker:{trackingThreshold:0,liveTolerance:15},
            html5:{vhs:{overrideNative:true,smoothQualityChange:true,allowSeeksWithinUnsafeLiveWindow:true,handlePartialData:true,experimentalBufferBasedABR:true},nativeAudioTracks:false,nativeVideoTracks:false},
            controlBar:{playToggle:true,volumePanel:{inline:true},pictureInPictureToggle:true,fullscreenToggle:true,progressControl:true,liveDisplay:true,currentTimeDisplay:false,timeDivider:false,durationDisplay:false,remainingTimeDisplay:false},
            controls:true,autoplay:false,preload:'auto',playsinline:true,
            errorDisplay:false,responsive:true,fluid:true,aspectRatio:'16:9'
        });
        var npLabel=document.getElementById('np-label'),npTitle=document.getElementById('np-title'),npArtist=document.getElementById('np-artist');
        var srcProgram=document.getElementById('src-program'),srcLive=document.getElementById('src-live');
        var card=document.getElementById('card'),switchOverlay=document.getElementById('switch-overlay'),switchText=document.getElementById('switch-text');
        var currentMode='autodj',switching=false,recovering=false,HLS='/hls/current/index.m3u8';
        function setMode(m){var prev=currentMode;currentMode=m;var live=m==='live';document.body.classList.toggle('live-mode',live);srcProgram.classList.toggle('active',!live);srcLive.classList.toggle('active',live);card.classList.toggle('live',live);if(prev!==m&&prev!==null&&!player.paused()){showSwitch(live?'Switching to Live...':'Switching to Program...')}}
        function showSwitch(msg){if(switching)return;switching=true;switchText.textContent=msg;switchOverlay.classList.add('visible');setTimeout(function(){switchOverlay.classList.remove('visible');switching=false},3000)}
        function poll(){fetch('/api/nowplaying?'+Date.now()).then(function(r){return r.json()}).then(function(d){var m=d.mode==='live'?'live':'autodj';setMode(m);if(m==='live'){npLabel.textContent='LIVE';npTitle.textContent=d.title||'LIVE';npArtist.textContent=d.artist||''}else{npLabel.textContent='NOW PLAYING';npTitle.textContent=d.title||'Unknown Track';npArtist.textContent=d.artist||'Unknown Artist'}}).catch(function(){})}
        poll();setInterval(poll,3000);
        var retries=0;
        player.on('error',function(){if(recovering)return;recovering=true;if(retries>=5){npTitle.textContent='Stream unavailable';recovering=false;retries=0;return}retries++;setTimeout(function(){player.src({src:HLS,type:'application/x-mpegURL'});player.load();player.play().catch(function(){});recovering=false},3000)});
        player.on('playing',function(){retries=0;try{var lt=player.liveTracker;if(lt&&lt.isLive()&&lt.behindLiveEdge()){lt.seekToLiveEdge()}}catch(e){}});
        var rt;function onRz(){clearTimeout(rt);rt=setTimeout(function(){player.dimensions(undefined,undefined)},200)}
        window.addEventListener('resize',onRz);window.addEventListener('orientationchange',onRz);
        var unlocked=false;document.addEventListener('touchstart',function u(){if(unlocked)return;unlocked=true;if(player.paused()){var p=player.play();if(p&&p.catch)p.catch(function(){})}document.removeEventListener('touchstart',u)},{once:true,passive:true});
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
  <rect width="1920" height="1080" fill="#050505"/>
  <circle cx="300" cy="900" r="400" fill="#2563eb" opacity="0.03"/>
  <circle cx="1600" cy="150" r="300" fill="#7c3aed" opacity="0.03"/>
  <text x="960" y="490" text-anchor="middle" font-family="Arial,Helvetica,sans-serif"
        font-size="68" font-weight="bold" fill="#d4d4d4">People We <tspan fill="#2563eb">Like</tspan></text>
  <text x="960" y="570" text-anchor="middle" font-family="Arial,Helvetica,sans-serif"
        font-size="28" fill="#404040" letter-spacing="10">RADIO</text>
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
echo "  - Video.js 8 fluid player (16:9) on /hls/current/index.m3u8"
echo "  - Program / Live pill indicators"
echo "  - Video.js native controls: play, volume, PiP, fullscreen"
echo "  - Seamless switching via HLS discontinuity tags"
echo "  - Automatic error recovery (5 retries)"
echo "  - Live edge seeking on source switch"
echo "  - Transition overlay animation"
echo "  - /api/nowplaying polling every 3s"
echo "  - Theme shift: electric blue Program / red Live"
echo "  - Underground luxury dark design"
echo "  - Fully responsive: iPhone SE to 4K"
echo "  - iOS: playsinline, safe-area, audio unlock"
echo "  - Landscape phone compact mode"
echo ""
echo "Player URL: https://radio.peoplewelike.club/"
echo ""
echo "Backend services required:"
echo "  systemctl status radio-switchd      # writes /run/radio/active"
echo "  systemctl status radio-hls-relay    # writes /hls/current/"
echo "  systemctl status liquidsoap-autodj  # AutoDJ audio"
echo "  systemctl status autodj-video-overlay  # FFmpeg video loop"
echo ""
