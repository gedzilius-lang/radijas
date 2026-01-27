#!/usr/bin/env bash
###############################################################################
# UPGRADE PLAYER - Enhanced Frontend
# People We Like Radio - Dark Purple Theme with Chat
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Upgrading Player to Enhanced Version"
echo "=============================================="

# Backup existing player
if [[ -f /var/www/radio.peoplewelike.club/index.html ]]; then
    cp /var/www/radio.peoplewelike.club/index.html \
       /var/www/radio.peoplewelike.club/index.html.backup.$(date +%s)
    echo "[0/4] Backed up existing player"
fi

# Create enhanced player
echo "[1/4] Creating enhanced index.html..."
cat > /var/www/radio.peoplewelike.club/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>People We Like Radio</title>
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        :root {
            --bg-dark: #0d0a1a;
            --bg-card: #1a1329;
            --bg-card-hover: #241a38;
            --purple-primary: #6b46c1;
            --purple-light: #9f7aea;
            --purple-glow: rgba(107, 70, 193, 0.4);
            --red-live: #e53e3e;
            --red-glow: rgba(229, 62, 62, 0.6);
            --text-primary: #e2e8f0;
            --text-muted: #a0aec0;
            --text-dim: #718096;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-dark);
            min-height: 100vh;
            color: var(--text-primary);
            overflow-x: hidden;
        }

        /* Animated background */
        .bg-animation {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: -1;
            background:
                radial-gradient(ellipse at 20% 80%, rgba(107, 70, 193, 0.15) 0%, transparent 50%),
                radial-gradient(ellipse at 80% 20%, rgba(159, 122, 234, 0.1) 0%, transparent 50%),
                radial-gradient(ellipse at 50% 50%, rgba(107, 70, 193, 0.05) 0%, transparent 70%);
            animation: bgPulse 8s ease-in-out infinite;
        }

        @keyframes bgPulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.7; }
        }

        /* Floating particles */
        .particles {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: -1;
            overflow: hidden;
            pointer-events: none;
        }

        .particle {
            position: absolute;
            width: 4px;
            height: 4px;
            background: var(--purple-light);
            border-radius: 50%;
            opacity: 0.3;
            animation: float 15s infinite ease-in-out;
        }

        @keyframes float {
            0%, 100% { transform: translateY(100vh) rotate(0deg); opacity: 0; }
            10% { opacity: 0.3; }
            90% { opacity: 0.3; }
            100% { transform: translateY(-100vh) rotate(720deg); opacity: 0; }
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
            display: grid;
            grid-template-columns: 1fr 380px;
            gap: 20px;
            min-height: 100vh;
        }

        @media (max-width: 1100px) {
            .container {
                grid-template-columns: 1fr;
            }
        }

        /* Header */
        header {
            grid-column: 1 / -1;
            text-align: center;
            padding: 30px 20px 20px;
        }

        .logo {
            font-size: 2em;
            font-weight: 700;
            background: linear-gradient(135deg, var(--purple-light), var(--purple-primary));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            letter-spacing: -1px;
        }

        .tagline {
            color: var(--text-dim);
            font-size: 0.9em;
            margin-top: 5px;
            letter-spacing: 2px;
            text-transform: uppercase;
        }

        /* Main content */
        .main-content {
            display: flex;
            flex-direction: column;
            gap: 20px;
        }

        /* Player card */
        .player-card {
            background: var(--bg-card);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
            border: 1px solid rgba(107, 70, 193, 0.2);
            transition: box-shadow 0.3s ease;
        }

        .player-card:hover {
            box-shadow: 0 25px 70px rgba(0, 0, 0, 0.6), 0 0 40px var(--purple-glow);
        }

        .player-card.live-active {
            border-color: rgba(229, 62, 62, 0.4);
            box-shadow: 0 25px 70px rgba(0, 0, 0, 0.6), 0 0 60px var(--red-glow);
        }

        /* Video container */
        .video-wrapper {
            position: relative;
            aspect-ratio: 16/9;
            background: #000;
        }

        .video-wrapper.hidden {
            display: none;
        }

        .video-js {
            width: 100%;
            height: 100%;
        }

        /* Audio-only mode */
        .audio-mode {
            aspect-ratio: 16/9;
            background: linear-gradient(135deg, var(--bg-dark) 0%, #1a1329 100%);
            display: none;
            align-items: center;
            justify-content: center;
            flex-direction: column;
            gap: 20px;
        }

        .audio-mode.active {
            display: flex;
        }

        .audio-visualizer {
            display: flex;
            align-items: flex-end;
            gap: 4px;
            height: 80px;
        }

        .audio-bar {
            width: 8px;
            background: linear-gradient(to top, var(--purple-primary), var(--purple-light));
            border-radius: 4px;
            animation: audioBar 0.8s ease-in-out infinite;
        }

        @keyframes audioBar {
            0%, 100% { height: 20px; }
            50% { height: 60px; }
        }

        .audio-bar:nth-child(1) { animation-delay: 0s; }
        .audio-bar:nth-child(2) { animation-delay: 0.1s; }
        .audio-bar:nth-child(3) { animation-delay: 0.2s; }
        .audio-bar:nth-child(4) { animation-delay: 0.3s; }
        .audio-bar:nth-child(5) { animation-delay: 0.4s; }
        .audio-bar:nth-child(6) { animation-delay: 0.3s; }
        .audio-bar:nth-child(7) { animation-delay: 0.2s; }
        .audio-bar:nth-child(8) { animation-delay: 0.1s; }

        .audio-text {
            color: var(--text-muted);
            font-size: 0.9em;
        }

        /* Now playing bar */
        .now-playing {
            padding: 20px;
            background: rgba(0, 0, 0, 0.3);
            display: flex;
            align-items: center;
            gap: 16px;
        }

        .np-icon {
            width: 50px;
            height: 50px;
            background: linear-gradient(135deg, var(--purple-primary), var(--purple-light));
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
            flex-shrink: 0;
            animation: iconPulse 2s ease-in-out infinite;
        }

        @keyframes iconPulse {
            0%, 100% { transform: scale(1); }
            50% { transform: scale(1.05); }
        }

        .np-info {
            flex-grow: 1;
            min-width: 0;
        }

        .np-label {
            font-size: 0.7em;
            text-transform: uppercase;
            letter-spacing: 2px;
            color: var(--text-dim);
            margin-bottom: 4px;
        }

        .np-title {
            font-size: 1.1em;
            font-weight: 600;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .np-artist {
            font-size: 0.9em;
            color: var(--text-muted);
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        /* Status indicator */
        .status-indicator {
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 8px 16px;
            border-radius: 20px;
            font-size: 0.75em;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            transition: all 0.3s ease;
        }

        .status-indicator.autodj {
            background: rgba(107, 70, 193, 0.2);
            border: 1px solid rgba(107, 70, 193, 0.4);
            color: var(--purple-light);
        }

        .status-indicator.live {
            background: rgba(229, 62, 62, 0.2);
            border: 1px solid rgba(229, 62, 62, 0.4);
            color: var(--red-live);
            animation: liveGlow 1.5s ease-in-out infinite;
        }

        @keyframes liveGlow {
            0%, 100% { box-shadow: 0 0 10px var(--red-glow); }
            50% { box-shadow: 0 0 25px var(--red-glow), 0 0 40px var(--red-glow); }
        }

        .status-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: currentColor;
        }

        .status-indicator.live .status-dot {
            animation: blink 1s infinite;
        }

        @keyframes blink {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.3; }
        }

        /* Controls */
        .controls {
            padding: 16px 20px;
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
            justify-content: center;
            border-top: 1px solid rgba(107, 70, 193, 0.1);
        }

        .btn {
            padding: 12px 20px;
            border: none;
            border-radius: 10px;
            font-size: 0.9em;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        .btn-primary {
            background: linear-gradient(135deg, var(--purple-primary), var(--purple-light));
            color: white;
        }

        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 30px var(--purple-glow);
        }

        .btn-secondary {
            background: rgba(107, 70, 193, 0.15);
            color: var(--purple-light);
            border: 1px solid rgba(107, 70, 193, 0.3);
        }

        .btn-secondary:hover {
            background: rgba(107, 70, 193, 0.25);
        }

        .btn-secondary.active {
            background: rgba(107, 70, 193, 0.3);
            border-color: var(--purple-light);
        }

        /* Stats bar */
        .stats-bar {
            padding: 12px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            background: rgba(0, 0, 0, 0.2);
            font-size: 0.85em;
            color: var(--text-muted);
        }

        .listeners {
            display: flex;
            align-items: center;
            gap: 6px;
        }

        .listener-dot {
            width: 8px;
            height: 8px;
            background: #48bb78;
            border-radius: 50%;
            animation: pulse 2s infinite;
        }

        @keyframes pulse {
            0%, 100% { transform: scale(1); opacity: 1; }
            50% { transform: scale(1.2); opacity: 0.7; }
        }

        /* Chat sidebar */
        .chat-card {
            background: var(--bg-card);
            border-radius: 16px;
            display: flex;
            flex-direction: column;
            height: calc(100vh - 160px);
            min-height: 500px;
            border: 1px solid rgba(107, 70, 193, 0.2);
        }

        .chat-header {
            padding: 16px 20px;
            border-bottom: 1px solid rgba(107, 70, 193, 0.1);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .chat-title {
            font-weight: 600;
            font-size: 1em;
        }

        .chat-online {
            font-size: 0.8em;
            color: var(--text-dim);
        }

        .chat-messages {
            flex-grow: 1;
            overflow-y: auto;
            padding: 16px;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }

        .chat-messages::-webkit-scrollbar {
            width: 6px;
        }

        .chat-messages::-webkit-scrollbar-track {
            background: transparent;
        }

        .chat-messages::-webkit-scrollbar-thumb {
            background: rgba(107, 70, 193, 0.3);
            border-radius: 3px;
        }

        .chat-message {
            display: flex;
            gap: 10px;
            animation: fadeIn 0.3s ease;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .chat-avatar {
            width: 32px;
            height: 32px;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 14px;
            flex-shrink: 0;
        }

        .chat-bubble {
            background: rgba(107, 70, 193, 0.1);
            padding: 10px 14px;
            border-radius: 12px;
            border-top-left-radius: 4px;
            max-width: 280px;
        }

        .chat-bubble.own {
            background: rgba(107, 70, 193, 0.25);
            border-top-left-radius: 12px;
            border-top-right-radius: 4px;
            margin-left: auto;
        }

        .chat-name {
            font-size: 0.75em;
            font-weight: 600;
            margin-bottom: 4px;
        }

        .chat-text {
            font-size: 0.9em;
            line-height: 1.4;
            word-wrap: break-word;
        }

        .chat-time {
            font-size: 0.7em;
            color: var(--text-dim);
            margin-top: 4px;
        }

        .chat-input-area {
            padding: 16px;
            border-top: 1px solid rgba(107, 70, 193, 0.1);
            display: flex;
            gap: 10px;
        }

        .chat-input {
            flex-grow: 1;
            padding: 12px 16px;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid rgba(107, 70, 193, 0.2);
            border-radius: 10px;
            color: var(--text-primary);
            font-size: 0.9em;
            outline: none;
            transition: border-color 0.2s;
        }

        .chat-input:focus {
            border-color: var(--purple-primary);
        }

        .chat-input::placeholder {
            color: var(--text-dim);
        }

        .chat-send {
            padding: 12px 16px;
            background: var(--purple-primary);
            border: none;
            border-radius: 10px;
            color: white;
            cursor: pointer;
            transition: all 0.2s;
        }

        .chat-send:hover {
            background: var(--purple-light);
        }

        /* System message */
        .chat-system {
            text-align: center;
            font-size: 0.8em;
            color: var(--text-dim);
            padding: 8px;
        }

        /* Mobile chat toggle */
        .chat-toggle-mobile {
            display: none;
            position: fixed;
            bottom: 20px;
            right: 20px;
            width: 56px;
            height: 56px;
            background: var(--purple-primary);
            border: none;
            border-radius: 50%;
            color: white;
            font-size: 24px;
            cursor: pointer;
            box-shadow: 0 4px 20px var(--purple-glow);
            z-index: 100;
        }

        @media (max-width: 1100px) {
            .chat-card {
                position: fixed;
                top: 0;
                right: -400px;
                width: 100%;
                max-width: 380px;
                height: 100vh;
                border-radius: 0;
                z-index: 200;
                transition: right 0.3s ease;
            }

            .chat-card.open {
                right: 0;
            }

            .chat-toggle-mobile {
                display: flex;
                align-items: center;
                justify-content: center;
            }

            .chat-overlay {
                display: none;
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background: rgba(0, 0, 0, 0.5);
                z-index: 150;
            }

            .chat-overlay.active {
                display: block;
            }
        }

        /* Footer */
        footer {
            grid-column: 1 / -1;
            text-align: center;
            padding: 30px 20px;
            color: var(--text-dim);
            font-size: 0.85em;
        }

        footer a {
            color: var(--purple-light);
            text-decoration: none;
        }

        /* Video.js custom theme */
        .video-js .vjs-big-play-button {
            background: var(--purple-primary);
            border: none;
            border-radius: 50%;
            width: 80px;
            height: 80px;
            line-height: 80px;
        }

        .video-js:hover .vjs-big-play-button {
            background: var(--purple-light);
        }

        .video-js .vjs-control-bar {
            background: rgba(13, 10, 26, 0.9);
        }

        .video-js .vjs-play-progress,
        .video-js .vjs-volume-level {
            background: var(--purple-primary);
        }

        .video-js .vjs-slider:focus {
            box-shadow: 0 0 0 3px var(--purple-glow);
        }
    </style>
</head>
<body>
    <div class="bg-animation"></div>
    <div class="particles" id="particles"></div>
    <div class="chat-overlay" id="chat-overlay"></div>

    <div class="container">
        <header>
            <div class="logo">People We Like</div>
            <div class="tagline">Radio</div>
        </header>

        <div class="main-content">
            <div class="player-card" id="player-card">
                <div class="video-wrapper" id="video-wrapper">
                    <video
                        id="radio-player"
                        class="video-js vjs-big-play-centered"
                        controls
                        preload="auto"
                        poster="/poster.jpg">
                        <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                    </video>
                </div>

                <div class="audio-mode" id="audio-mode">
                    <div class="audio-visualizer">
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                        <div class="audio-bar"></div>
                    </div>
                    <div class="audio-text">Audio Only Mode</div>
                </div>

                <div class="now-playing">
                    <div class="np-icon">♪</div>
                    <div class="np-info">
                        <div class="np-label" id="np-label">Now Playing</div>
                        <div class="np-title" id="np-title">Loading...</div>
                        <div class="np-artist" id="np-artist"></div>
                    </div>
                    <div class="status-indicator autodj" id="status-indicator">
                        <span class="status-dot"></span>
                        <span id="status-text">AutoDJ</span>
                    </div>
                </div>

                <div class="controls">
                    <button class="btn btn-primary" id="btn-play">Play</button>
                    <button class="btn btn-secondary" id="btn-mute">Mute</button>
                    <button class="btn btn-secondary" id="btn-video">Video Off</button>
                    <button class="btn btn-secondary" id="btn-fullscreen">Fullscreen</button>
                </div>

                <div class="stats-bar">
                    <div class="listeners">
                        <span class="listener-dot"></span>
                        <span id="listener-count">-- listeners</span>
                    </div>
                    <div id="stream-quality">1080p</div>
                </div>
            </div>
        </div>

        <div class="chat-card" id="chat-card">
            <div class="chat-header">
                <div class="chat-title">Chat</div>
                <div class="chat-online" id="chat-online">-- online</div>
            </div>
            <div class="chat-messages" id="chat-messages">
                <div class="chat-system">Welcome to the chat! Be respectful.</div>
            </div>
            <div class="chat-input-area">
                <input type="text" class="chat-input" id="chat-input" placeholder="Say something..." maxlength="200">
                <button class="chat-send" id="chat-send">Send</button>
            </div>
        </div>

        <footer>
            <p>&copy; 2024 People We Like Radio | <a href="https://peoplewelike.club">peoplewelike.club</a></p>
        </footer>
    </div>

    <button class="chat-toggle-mobile" id="chat-toggle">💬</button>

    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        // ============================================
        // Particle Animation
        // ============================================
        (function initParticles() {
            const container = document.getElementById('particles');
            for (let i = 0; i < 20; i++) {
                const particle = document.createElement('div');
                particle.className = 'particle';
                particle.style.left = Math.random() * 100 + '%';
                particle.style.animationDelay = Math.random() * 15 + 's';
                particle.style.animationDuration = (15 + Math.random() * 10) + 's';
                container.appendChild(particle);
            }
        })();

        // ============================================
        // Video Player
        // ============================================
        const player = videojs('radio-player', {
            liveui: true,
            html5: {
                vhs: {
                    overrideNative: true,
                    smoothQualityChange: true,
                    allowSeeksWithinUnsafeLiveWindow: true
                },
                nativeAudioTracks: false,
                nativeVideoTracks: false
            },
            controls: true,
            autoplay: false,
            preload: 'auto'
        });

        const btnPlay = document.getElementById('btn-play');
        const btnMute = document.getElementById('btn-mute');
        const btnVideo = document.getElementById('btn-video');
        const btnFullscreen = document.getElementById('btn-fullscreen');
        const videoWrapper = document.getElementById('video-wrapper');
        const audioMode = document.getElementById('audio-mode');
        let videoEnabled = true;

        btnPlay.addEventListener('click', () => {
            if (player.paused()) {
                player.play();
            } else {
                player.pause();
            }
        });

        btnMute.addEventListener('click', () => {
            player.muted(!player.muted());
            btnMute.textContent = player.muted() ? 'Unmute' : 'Mute';
            btnMute.classList.toggle('active', player.muted());
        });

        btnVideo.addEventListener('click', () => {
            videoEnabled = !videoEnabled;
            if (videoEnabled) {
                videoWrapper.classList.remove('hidden');
                audioMode.classList.remove('active');
                btnVideo.textContent = 'Video Off';
                btnVideo.classList.remove('active');
            } else {
                videoWrapper.classList.add('hidden');
                audioMode.classList.add('active');
                btnVideo.textContent = 'Video On';
                btnVideo.classList.add('active');
            }
        });

        btnFullscreen.addEventListener('click', () => {
            if (player.isFullscreen()) {
                player.exitFullscreen();
            } else {
                player.requestFullscreen();
            }
        });

        player.on('play', () => { btnPlay.textContent = 'Pause'; });
        player.on('pause', () => { btnPlay.textContent = 'Play'; });

        player.on('error', () => {
            console.log('Player error, recovering...');
            setTimeout(() => {
                player.src({ src: '/hls/current/index.m3u8', type: 'application/x-mpegURL' });
                player.load();
            }, 3000);
        });

        // ============================================
        // Now Playing & Status
        // ============================================
        const npTitle = document.getElementById('np-title');
        const npArtist = document.getElementById('np-artist');
        const npLabel = document.getElementById('np-label');
        const statusIndicator = document.getElementById('status-indicator');
        const statusText = document.getElementById('status-text');
        const playerCard = document.getElementById('player-card');

        async function updateNowPlaying() {
            try {
                const response = await fetch('/api/nowplaying?' + Date.now());
                const data = await response.json();

                if (data.mode === 'live') {
                    npLabel.textContent = 'LIVE BROADCAST';
                    npTitle.textContent = data.title || 'LIVE SHOW';
                    npArtist.textContent = data.artist || '';
                    statusText.textContent = 'LIVE';
                    statusIndicator.className = 'status-indicator live';
                    playerCard.classList.add('live-active');
                } else {
                    npLabel.textContent = 'Now Playing';
                    npTitle.textContent = data.title || 'Unknown Track';
                    npArtist.textContent = data.artist || 'Unknown Artist';
                    statusText.textContent = 'AutoDJ';
                    statusIndicator.className = 'status-indicator autodj';
                    playerCard.classList.remove('live-active');
                }

                // Update listener count if available
                if (data.listeners !== undefined) {
                    document.getElementById('listener-count').textContent =
                        data.listeners + (data.listeners === 1 ? ' listener' : ' listeners');
                }
            } catch (err) {
                console.error('Failed to fetch now playing:', err);
            }
        }

        updateNowPlaying();
        setInterval(updateNowPlaying, 5000);

        // ============================================
        // Chat System (Local Demo)
        // ============================================
        const adjectives = ['Happy', 'Cosmic', 'Electric', 'Mellow', 'Groovy', 'Chill', 'Funky', 'Dreamy', 'Neon', 'Mystic'];
        const nouns = ['Listener', 'Voyager', 'Soul', 'Wanderer', 'Viber', 'Spirit', 'Rider', 'Drifter', 'Dreamer', 'Nomad'];
        const colors = ['#e53e3e', '#dd6b20', '#d69e2e', '#38a169', '#319795', '#3182ce', '#5a67d8', '#805ad5', '#d53f8c'];

        function generateNickname() {
            const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
            const noun = nouns[Math.floor(Math.random() * nouns.length)];
            const num = Math.floor(Math.random() * 99);
            return adj + noun + num;
        }

        function getRandomColor() {
            return colors[Math.floor(Math.random() * colors.length)];
        }

        const myNickname = generateNickname();
        const myColor = getRandomColor();
        const chatMessages = document.getElementById('chat-messages');
        const chatInput = document.getElementById('chat-input');
        const chatSend = document.getElementById('chat-send');

        // Simulated chat users
        const simulatedUsers = [
            { name: 'ChillViber42', color: '#38a169' },
            { name: 'NeonDreamer7', color: '#d53f8c' },
            { name: 'CosmicSoul88', color: '#3182ce' }
        ];

        const simulatedMessages = [
            'loving this track!',
            'anyone else vibing rn?',
            'this beat is fire',
            'perfect for late night coding',
            'the visuals are sick',
            'who picked this playlist?',
            'tune',
            'beautiful',
            'this is why i love this radio'
        ];

        function addMessage(nickname, color, text, isOwn = false) {
            const msgEl = document.createElement('div');
            msgEl.className = 'chat-message';

            const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

            msgEl.innerHTML = `
                <div class="chat-avatar" style="background: ${color}20; color: ${color};">${nickname[0]}</div>
                <div class="chat-bubble${isOwn ? ' own' : ''}">
                    <div class="chat-name" style="color: ${color};">${nickname}</div>
                    <div class="chat-text">${escapeHtml(text)}</div>
                    <div class="chat-time">${time}</div>
                </div>
            `;

            chatMessages.appendChild(msgEl);
            chatMessages.scrollTop = chatMessages.scrollHeight;

            // Keep only last 50 messages
            while (chatMessages.children.length > 51) {
                chatMessages.removeChild(chatMessages.children[1]);
            }
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function sendMessage() {
            const text = chatInput.value.trim();
            if (!text) return;

            addMessage(myNickname, myColor, text, true);
            chatInput.value = '';

            // Store in localStorage for persistence demo
            const messages = JSON.parse(localStorage.getItem('chatMessages') || '[]');
            messages.push({ nickname: myNickname, color: myColor, text, time: Date.now() });
            localStorage.setItem('chatMessages', JSON.stringify(messages.slice(-50)));
        }

        chatSend.addEventListener('click', sendMessage);
        chatInput.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        // Simulate random chat activity
        function simulateChat() {
            if (Math.random() > 0.7) {
                const user = simulatedUsers[Math.floor(Math.random() * simulatedUsers.length)];
                const msg = simulatedMessages[Math.floor(Math.random() * simulatedMessages.length)];
                addMessage(user.name, user.color, msg);
            }
            setTimeout(simulateChat, 15000 + Math.random() * 30000);
        }

        // Start simulation after delay
        setTimeout(simulateChat, 10000);

        // Update online count
        function updateOnlineCount() {
            const count = 3 + Math.floor(Math.random() * 5);
            document.getElementById('chat-online').textContent = count + ' online';
        }
        updateOnlineCount();
        setInterval(updateOnlineCount, 30000);

        // ============================================
        // Mobile Chat Toggle
        // ============================================
        const chatCard = document.getElementById('chat-card');
        const chatToggle = document.getElementById('chat-toggle');
        const chatOverlay = document.getElementById('chat-overlay');

        chatToggle.addEventListener('click', () => {
            chatCard.classList.toggle('open');
            chatOverlay.classList.toggle('active');
        });

        chatOverlay.addEventListener('click', () => {
            chatCard.classList.remove('open');
            chatOverlay.classList.remove('active');
        });

        // ============================================
        // Simulated Listener Count
        // ============================================
        function updateListenerCount() {
            const base = 12;
            const variance = Math.floor(Math.random() * 8) - 4;
            const count = Math.max(1, base + variance);
            document.getElementById('listener-count').textContent =
                count + (count === 1 ? ' listener' : ' listeners');
        }
        updateListenerCount();
        setInterval(updateListenerCount, 60000);
    </script>
</body>
</html>
HTMLEOF
echo "    Created enhanced index.html"

# Update poster with dark purple theme
echo "[2/4] Creating themed poster..."
cat > /var/www/radio.peoplewelike.club/poster.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#0d0a1a"/>
      <stop offset="50%" style="stop-color:#1a1329"/>
      <stop offset="100%" style="stop-color:#0d0a1a"/>
    </linearGradient>
    <linearGradient id="text" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#9f7aea"/>
      <stop offset="100%" style="stop-color:#6b46c1"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <circle cx="200" cy="800" r="300" fill="#6b46c1" opacity="0.1"/>
  <circle cx="1700" cy="200" r="250" fill="#9f7aea" opacity="0.08"/>
  <text x="960" y="480" text-anchor="middle" font-family="Arial, sans-serif" font-size="72" font-weight="bold" fill="url(#text)">People We Like</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial, sans-serif" font-size="36" fill="#a0aec0" letter-spacing="8">RADIO</text>
  <text x="960" y="700" text-anchor="middle" font-family="Arial, sans-serif" font-size="24" fill="#718096">Loading stream...</text>
</svg>
SVGEOF

if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i /var/www/radio.peoplewelike.club/poster.svg \
           -vf "scale=1920:1080" \
           /var/www/radio.peoplewelike.club/poster.jpg 2>/dev/null || true
    echo "    Created poster.jpg"
fi

# Update error pages with purple theme
echo "[3/4] Updating error pages..."
cat > /var/www/radio.peoplewelike.club/404.html <<'404EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - People We Like Radio</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d0a1a;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #e2e8f0;
            margin: 0;
        }
        .error { text-align: center; }
        h1 {
            font-size: 6em;
            margin: 0;
            background: linear-gradient(135deg, #9f7aea, #6b46c1);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        p { color: #718096; font-size: 1.2em; }
        a { color: #9f7aea; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="error">
        <h1>404</h1>
        <p>Page not found</p>
        <p><a href="/">Back to Radio</a></p>
    </div>
</body>
</html>
404EOF

cat > /var/www/radio.peoplewelike.club/50x.html <<'50XEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Error - People We Like Radio</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d0a1a;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #e2e8f0;
            margin: 0;
        }
        .error { text-align: center; }
        h1 { font-size: 4em; margin: 0; color: #e53e3e; }
        p { color: #718096; font-size: 1.2em; }
        a { color: #9f7aea; text-decoration: none; }
    </style>
</head>
<body>
    <div class="error">
        <h1>Server Error</h1>
        <p>Something went wrong. Please try again later.</p>
        <p><a href="/">Back to Radio</a></p>
    </div>
</body>
</html>
50XEOF
echo "    Updated error pages"

# Set permissions
echo "[4/4] Setting permissions..."
chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

echo ""
echo "=============================================="
echo "  Player Upgraded Successfully!"
echo "=============================================="
echo ""
echo "Features added:"
echo "  - Dark purple theme with subtle animations"
echo "  - Floating particle effects"
echo "  - AutoDJ/LIVE status indicator with red glow"
echo "  - Video toggle button (audio-only mode)"
echo "  - Chat sidebar with auto-assigned nicknames"
echo "  - Mobile responsive with slide-out chat"
echo "  - Listener count display"
echo "  - Themed error pages"
echo ""
echo "Player URL: https://radio.peoplewelike.club/"
echo ""
