#!/usr/bin/env bash
###############################################################################
# CREATE VIDEO.JS PLAYER PAGE
# People We Like Radio Installation - Step 8
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Creating Video.js Player Page"
echo "=============================================="

# Create web root
mkdir -p /var/www/radio.peoplewelike.club

# Create main player page
echo "[1/3] Creating index.html..."
cat > /var/www/radio.peoplewelike.club/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>People We Like Radio</title>

    <!-- Video.js CSS -->
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">

    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            min-height: 100vh;
            color: #fff;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }

        header {
            text-align: center;
            padding: 40px 20px;
        }

        header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            background: linear-gradient(90deg, #e94560, #f39c12);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        header p {
            color: #a0a0a0;
            font-size: 1.1em;
        }

        .player-container {
            max-width: 960px;
            margin: 0 auto;
            background: rgba(0, 0, 0, 0.3);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
        }

        .video-js {
            width: 100%;
            aspect-ratio: 16/9;
        }

        .now-playing {
            padding: 20px 30px;
            background: rgba(0, 0, 0, 0.4);
            display: flex;
            align-items: center;
            gap: 20px;
        }

        .now-playing-icon {
            width: 60px;
            height: 60px;
            background: linear-gradient(135deg, #e94560, #f39c12);
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
            flex-shrink: 0;
        }

        .now-playing-info {
            flex-grow: 1;
            min-width: 0;
        }

        .now-playing-label {
            font-size: 0.75em;
            text-transform: uppercase;
            letter-spacing: 2px;
            color: #888;
            margin-bottom: 4px;
        }

        .now-playing-title {
            font-size: 1.3em;
            font-weight: 600;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .now-playing-artist {
            font-size: 1em;
            color: #a0a0a0;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .status-badge {
            padding: 6px 16px;
            border-radius: 20px;
            font-size: 0.8em;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .status-badge.live {
            background: #e94560;
            animation: pulse 2s infinite;
        }

        .status-badge.autodj {
            background: #3498db;
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.7; }
        }

        .controls {
            padding: 20px 30px;
            display: flex;
            gap: 10px;
            justify-content: center;
        }

        .btn {
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            font-size: 1em;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s;
        }

        .btn-primary {
            background: linear-gradient(135deg, #e94560, #f39c12);
            color: white;
        }

        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 30px rgba(233, 69, 96, 0.3);
        }

        .btn-secondary {
            background: rgba(255, 255, 255, 0.1);
            color: white;
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        .btn-secondary:hover {
            background: rgba(255, 255, 255, 0.2);
        }

        footer {
            text-align: center;
            padding: 40px 20px;
            color: #666;
            font-size: 0.9em;
        }

        footer a {
            color: #e94560;
            text-decoration: none;
        }

        @media (max-width: 600px) {
            header h1 {
                font-size: 1.8em;
            }

            .now-playing {
                flex-direction: column;
                text-align: center;
            }

            .now-playing-info {
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>People We Like Radio</h1>
            <p>24/7 Music & Live Shows</p>
        </header>

        <div class="player-container">
            <video
                id="radio-player"
                class="video-js vjs-big-play-centered vjs-theme-fantasy"
                controls
                preload="auto"
                poster="/poster.jpg"
                data-setup='{}'>
                <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                <p class="vjs-no-js">
                    To view this video please enable JavaScript, and consider upgrading to a
                    web browser that supports HTML5 video.
                </p>
            </video>

            <div class="now-playing">
                <div class="now-playing-icon">🎵</div>
                <div class="now-playing-info">
                    <div class="now-playing-label" id="np-label">Now Playing</div>
                    <div class="now-playing-title" id="np-title">Loading...</div>
                    <div class="now-playing-artist" id="np-artist"></div>
                </div>
                <div class="status-badge autodj" id="status-badge">AutoDJ</div>
            </div>

            <div class="controls">
                <button class="btn btn-primary" id="btn-play">▶ Play</button>
                <button class="btn btn-secondary" id="btn-mute">🔊 Mute</button>
                <button class="btn btn-secondary" id="btn-fullscreen">⛶ Fullscreen</button>
            </div>
        </div>

        <footer>
            <p>&copy; 2024 People We Like Radio |
               <a href="https://peoplewelike.club">peoplewelike.club</a>
            </p>
        </footer>
    </div>

    <!-- Video.js -->
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>

    <script>
        // Initialize player
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

        // Custom controls
        const btnPlay = document.getElementById('btn-play');
        const btnMute = document.getElementById('btn-mute');
        const btnFullscreen = document.getElementById('btn-fullscreen');

        btnPlay.addEventListener('click', () => {
            if (player.paused()) {
                player.play();
                btnPlay.textContent = '⏸ Pause';
            } else {
                player.pause();
                btnPlay.textContent = '▶ Play';
            }
        });

        btnMute.addEventListener('click', () => {
            player.muted(!player.muted());
            btnMute.textContent = player.muted() ? '🔇 Unmute' : '🔊 Mute';
        });

        btnFullscreen.addEventListener('click', () => {
            if (player.isFullscreen()) {
                player.exitFullscreen();
            } else {
                player.requestFullscreen();
            }
        });

        player.on('play', () => {
            btnPlay.textContent = '⏸ Pause';
        });

        player.on('pause', () => {
            btnPlay.textContent = '▶ Play';
        });

        // Now Playing updates
        const npTitle = document.getElementById('np-title');
        const npArtist = document.getElementById('np-artist');
        const npLabel = document.getElementById('np-label');
        const statusBadge = document.getElementById('status-badge');

        async function updateNowPlaying() {
            try {
                const response = await fetch('/api/nowplaying?' + Date.now());
                const data = await response.json();

                if (data.mode === 'live') {
                    npLabel.textContent = 'LIVE BROADCAST';
                    npTitle.textContent = data.title || 'LIVE-SHOW';
                    npArtist.textContent = data.artist || '';
                    statusBadge.textContent = 'LIVE';
                    statusBadge.className = 'status-badge live';
                } else {
                    npLabel.textContent = 'Now Playing';
                    npTitle.textContent = data.title || 'Unknown Track';
                    npArtist.textContent = data.artist || 'Unknown Artist';
                    statusBadge.textContent = 'AutoDJ';
                    statusBadge.className = 'status-badge autodj';
                }
            } catch (err) {
                console.error('Failed to fetch now playing:', err);
            }
        }

        // Update now playing every 5 seconds
        updateNowPlaying();
        setInterval(updateNowPlaying, 5000);

        // Error handling and auto-recovery
        player.on('error', () => {
            console.log('Player error, attempting recovery...');
            setTimeout(() => {
                player.src({ src: '/hls/current/index.m3u8', type: 'application/x-mpegURL' });
                player.load();
            }, 3000);
        });
    </script>
</body>
</html>
HTMLEOF
echo "    Created index.html"

# Create a simple poster image placeholder
echo "[2/3] Creating poster placeholder..."
cat > /var/www/radio.peoplewelike.club/poster.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#1a1a2e"/>
      <stop offset="50%" style="stop-color:#16213e"/>
      <stop offset="100%" style="stop-color:#0f3460"/>
    </linearGradient>
  </defs>
  <rect width="1920" height="1080" fill="url(#bg)"/>
  <text x="960" y="480" text-anchor="middle" font-family="Arial, sans-serif" font-size="72" fill="#e94560">People We Like</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial, sans-serif" font-size="48" fill="#ffffff">RADIO</text>
  <text x="960" y="700" text-anchor="middle" font-family="Arial, sans-serif" font-size="24" fill="#888888">Loading stream...</text>
</svg>
SVGEOF
# Convert to JPG using ffmpeg if available
if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i /var/www/radio.peoplewelike.club/poster.svg \
           -vf "scale=1920:1080" \
           /var/www/radio.peoplewelike.club/poster.jpg 2>/dev/null || true
fi
echo "    Created poster image"

# Create 404 page
echo "[3/3] Creating error pages..."
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
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            margin: 0;
        }
        .error {
            text-align: center;
        }
        h1 {
            font-size: 6em;
            margin: 0;
            background: linear-gradient(90deg, #e94560, #f39c12);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        p { color: #888; font-size: 1.2em; }
        a { color: #e94560; text-decoration: none; }
    </style>
</head>
<body>
    <div class="error">
        <h1>404</h1>
        <p>Page not found</p>
        <p><a href="/">← Back to Radio</a></p>
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
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            margin: 0;
        }
        .error {
            text-align: center;
        }
        h1 {
            font-size: 4em;
            margin: 0;
            color: #e94560;
        }
        p { color: #888; font-size: 1.2em; }
        a { color: #e94560; text-decoration: none; }
    </style>
</head>
<body>
    <div class="error">
        <h1>Server Error</h1>
        <p>Something went wrong. Please try again later.</p>
        <p><a href="/">← Back to Radio</a></p>
    </div>
</body>
</html>
50XEOF
echo "    Created error pages"

# Set permissions
chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

echo ""
echo "=============================================="
echo "  Video.js Player Created"
echo "=============================================="
echo ""
echo "Files created:"
echo "  /var/www/radio.peoplewelike.club/index.html"
echo "  /var/www/radio.peoplewelike.club/poster.svg"
echo "  /var/www/radio.peoplewelike.club/poster.jpg"
echo "  /var/www/radio.peoplewelike.club/404.html"
echo "  /var/www/radio.peoplewelike.club/50x.html"
echo ""
echo "Player URL: https://radio.peoplewelike.club/"
echo ""
echo "Next step: Run ./09-finalize.sh"
