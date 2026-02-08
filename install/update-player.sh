#!/usr/bin/env bash
###############################################################################
# update-player.sh
# Updates only the web player (HTML/CSS/JS) on VPS
#
# Usage (on VPS as root):
#   curl -fsSL https://raw.githubusercontent.com/gedzilius-lang/radijas/claude/setup-radio-agent-instructions-ghStP/install/update-player.sh | bash
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK:${NC} $1"; }
step() { echo -e "\n${CYAN}>>> $1${NC}"; }

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root${NC}"; exit 1; fi

step "Deploying web player"
mkdir -p /var/www/radio.peoplewelike.club

cat > /var/www/radio.peoplewelike.club/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>People We Like Radio</title>
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root{--bg-dark:#0d0a1a;--bg-card:#1a1329;--purple-primary:#6b46c1;--purple-light:#9f7aea;--purple-glow:rgba(107,70,193,0.4);--red-live:#e53e3e;--red-glow:rgba(229,62,62,0.6);--text-primary:#e2e8f0;--text-muted:#a0aec0;--text-dim:#718096}
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:'Inter',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg-dark);min-height:100vh;color:var(--text-primary);overflow-x:hidden}
        .bg-animation{position:fixed;top:0;left:0;width:100%;height:100%;z-index:-1;background:radial-gradient(ellipse at 20% 80%,rgba(107,70,193,0.15) 0%,transparent 50%),radial-gradient(ellipse at 80% 20%,rgba(159,122,234,0.1) 0%,transparent 50%);animation:bgPulse 8s ease-in-out infinite}
        @keyframes bgPulse{0%,100%{opacity:1}50%{opacity:0.7}}
        .container{max-width:1000px;margin:0 auto;padding:20px}
        header{text-align:center;padding:30px 20px 20px}
        .logo{font-size:2em;font-weight:700;background:linear-gradient(135deg,var(--purple-light),var(--purple-primary));-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
        .tagline{color:var(--text-dim);font-size:0.9em;margin-top:5px;letter-spacing:2px;text-transform:uppercase}
        .player-card{background:var(--bg-card);border-radius:16px;overflow:hidden;box-shadow:0 20px 60px rgba(0,0,0,0.5);border:1px solid rgba(107,70,193,0.2)}
        .player-card.live-active{border-color:rgba(229,62,62,0.4);box-shadow:0 25px 70px rgba(0,0,0,0.6),0 0 60px var(--red-glow)}
        .video-js{width:100%;aspect-ratio:16/9}
        .now-playing{padding:20px;background:rgba(0,0,0,0.3);display:flex;align-items:center;gap:16px}
        .np-icon{width:50px;height:50px;background:linear-gradient(135deg,var(--purple-primary),var(--purple-light));border-radius:12px;display:flex;align-items:center;justify-content:center;font-size:24px;flex-shrink:0}
        .np-info{flex-grow:1;min-width:0}
        .np-label{font-size:0.7em;text-transform:uppercase;letter-spacing:2px;color:var(--text-dim);margin-bottom:4px}
        .np-title{font-size:1.1em;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .np-artist{font-size:0.9em;color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .status-indicator{display:flex;align-items:center;gap:8px;padding:8px 16px;border-radius:20px;font-size:0.75em;font-weight:600;text-transform:uppercase;letter-spacing:1px}
        .status-indicator.autodj{background:rgba(107,70,193,0.2);border:1px solid rgba(107,70,193,0.4);color:var(--purple-light)}
        .status-indicator.live{background:rgba(229,62,62,0.2);border:1px solid rgba(229,62,62,0.4);color:var(--red-live);animation:liveGlow 1.5s ease-in-out infinite}
        @keyframes liveGlow{0%,100%{box-shadow:0 0 10px var(--red-glow)}50%{box-shadow:0 0 25px var(--red-glow)}}
        .status-dot{width:8px;height:8px;border-radius:50%;background:currentColor}
        .status-indicator.live .status-dot{animation:blink 1s infinite}
        @keyframes blink{0%,100%{opacity:1}50%{opacity:0.3}}
        .controls{padding:16px 20px;display:flex;gap:10px;flex-wrap:wrap;justify-content:center;border-top:1px solid rgba(107,70,193,0.1)}
        .btn{padding:12px 20px;border:none;border-radius:10px;font-size:0.9em;font-weight:600;cursor:pointer;transition:all 0.2s}
        .btn-primary{background:linear-gradient(135deg,var(--purple-primary),var(--purple-light));color:white}
        .btn-primary:hover{transform:translateY(-2px);box-shadow:0 10px 30px var(--purple-glow)}
        .btn-secondary{background:rgba(107,70,193,0.15);color:var(--purple-light);border:1px solid rgba(107,70,193,0.3)}
        .btn-secondary:hover{background:rgba(107,70,193,0.25)}
        footer{text-align:center;padding:30px 20px;color:var(--text-dim);font-size:0.85em}
        footer a{color:var(--purple-light);text-decoration:none}
        .video-js .vjs-big-play-button{background:var(--purple-primary);border:none;border-radius:50%;width:80px;height:80px;line-height:80px}
        .video-js:hover .vjs-big-play-button{background:var(--purple-light)}
        .video-js .vjs-control-bar{background:rgba(13,10,26,0.9)}
        .video-js .vjs-play-progress,.video-js .vjs-volume-level{background:var(--purple-primary)}
        @media(max-width:600px){.logo{font-size:1.5em}.now-playing{flex-direction:column;text-align:center}}
    </style>
</head>
<body>
    <div class="bg-animation"></div>
    <div class="container">
        <header><div class="logo">People We Like</div><div class="tagline">Radio</div></header>
        <div class="player-card" id="player-card">
            <video id="radio-player" class="video-js vjs-big-play-centered" controls preload="auto" poster="/poster.jpg">
                <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
            </video>
            <div class="now-playing">
                <div class="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Loading...</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
                <div class="status-indicator autodj" id="status-indicator">
                    <span class="status-dot"></span><span id="status-text">AutoDJ</span>
                </div>
            </div>
            <div class="controls">
                <button class="btn btn-primary" id="btn-play">Play</button>
                <button class="btn btn-secondary" id="btn-mute">Mute</button>
                <button class="btn btn-secondary" id="btn-fullscreen">Fullscreen</button>
            </div>
        </div>
        <footer><p>&copy; 2024 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></p></footer>
    </div>
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        const player=videojs('radio-player',{liveui:true,html5:{vhs:{overrideNative:true,smoothQualityChange:true,allowSeeksWithinUnsafeLiveWindow:true},nativeAudioTracks:false,nativeVideoTracks:false},controls:true,autoplay:false,preload:'auto'});
        const bp=document.getElementById('btn-play'),bm=document.getElementById('btn-mute'),bf=document.getElementById('btn-fullscreen');
        bp.addEventListener('click',()=>{player.paused()?player.play():player.pause()});
        bm.addEventListener('click',()=>{player.muted(!player.muted());bm.textContent=player.muted()?'Unmute':'Mute'});
        bf.addEventListener('click',()=>{player.isFullscreen()?player.exitFullscreen():player.requestFullscreen()});
        player.on('play',()=>{bp.textContent='Pause'});player.on('pause',()=>{bp.textContent='Play'});
        player.on('error',()=>{setTimeout(()=>{player.src({src:'/hls/current/index.m3u8',type:'application/x-mpegURL'});player.load()},3000)});
        const nt=document.getElementById('np-title'),na=document.getElementById('np-artist'),nl=document.getElementById('np-label'),si=document.getElementById('status-indicator'),st=document.getElementById('status-text'),pc=document.getElementById('player-card');
        async function u(){try{const r=await fetch('/api/nowplaying?'+Date.now()),d=await r.json();if(d.mode==='live'){nl.textContent='LIVE BROADCAST';nt.textContent=d.title||'LIVE SHOW';na.textContent=d.artist||'';st.textContent='LIVE';si.className='status-indicator live';pc.classList.add('live-active')}else{nl.textContent='Now Playing';nt.textContent=d.title||'Unknown Track';na.textContent=d.artist||'Unknown Artist';st.textContent='AutoDJ';si.className='status-indicator autodj';pc.classList.remove('live-active')}}catch(e){}}
        u();setInterval(u,5000);
    </script>
</body>
</html>
HTMLEOF

chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club
ok "Web player updated"
echo -e "\n${GREEN}Done. Refresh https://radio.peoplewelike.club/${NC}"
