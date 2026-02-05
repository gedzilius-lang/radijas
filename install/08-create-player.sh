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
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d0d14;
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            color: #fff;
        }

        .player-wrap {
            width: 100%;
            max-width: 960px;
            padding: 20px;
        }

        h1 {
            text-align: center;
            font-size: 1.5em;
            font-weight: 400;
            margin-bottom: 20px;
            color: #a78bfa;
        }

        .video-container {
            position: relative;
            background: #1a1a24;
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 0 60px rgba(167, 139, 250, 0.15);
        }

        .video-js {
            width: 100%;
            aspect-ratio: 16/9;
        }

        /* Video.js purple theme */
        .video-js .vjs-big-play-button {
            background: rgba(167, 139, 250, 0.9);
            border: none;
            border-radius: 50%;
            width: 80px;
            height: 80px;
            line-height: 80px;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
        }
        .video-js .vjs-big-play-button:hover {
            background: #a78bfa;
        }
        .video-js .vjs-control-bar {
            background: rgba(13, 13, 20, 0.9);
        }
        .video-js .vjs-play-progress,
        .video-js .vjs-volume-level {
            background: #a78bfa;
        }
        .video-js .vjs-slider {
            background: rgba(167, 139, 250, 0.3);
        }

        .now-playing {
            display: flex;
            align-items: center;
            gap: 12px;
            padding: 16px 20px;
            background: #13131a;
            border-top: 1px solid #252530;
        }

        .np-status {
            padding: 4px 10px;
            border-radius: 4px;
            font-size: 0.7em;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            background: #7c3aed;
            flex-shrink: 0;
        }
        .np-status.live {
            background: #dc2626;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.6; }
        }

        .np-text {
            flex: 1;
            min-width: 0;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
            font-size: 0.9em;
            color: #9ca3af;
        }
        .np-text strong {
            color: #fff;
            font-weight: 500;
        }

        @media (max-width: 600px) {
            .player-wrap { padding: 10px; }
            h1 { font-size: 1.2em; }
            .now-playing { flex-direction: column; text-align: center; gap: 8px; }
            .np-text { white-space: normal; }
        }
    </style>
</head>
<body>
    <div class="player-wrap">
        <h1>People We Like Radio</h1>
        <div class="video-container">
            <video
                id="player"
                class="video-js vjs-big-play-centered"
                controls
                preload="auto"
                poster="/poster.jpg">
                <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
            </video>
            <div class="now-playing">
                <div class="np-status" id="status">AutoDJ</div>
                <div class="np-text" id="track">Ready to play</div>
            </div>
        </div>
    </div>

    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        const player = videojs('player', {
            liveui: true,
            html5: {
                vhs: {
                    overrideNative: true,
                    smoothQualityChange: true
                },
                nativeAudioTracks: false,
                nativeVideoTracks: false
            }
        });

        const statusEl = document.getElementById('status');
        const trackEl = document.getElementById('track');

        async function updateNowPlaying() {
            try {
                const res = await fetch('/api/nowplaying?t=' + Date.now());
                if (!res.ok) throw new Error('API error');
                const data = await res.json();

                if (data.mode === 'live') {
                    statusEl.textContent = 'LIVE';
                    statusEl.className = 'np-status live';
                    trackEl.innerHTML = data.title || 'Live Broadcast';
                } else {
                    statusEl.textContent = 'AutoDJ';
                    statusEl.className = 'np-status';
                    const title = data.title || 'Unknown';
                    const artist = data.artist || '';
                    trackEl.innerHTML = artist ? `<strong>${title}</strong> - ${artist}` : `<strong>${title}</strong>`;
                }
            } catch (e) {
                // API unavailable - show default state
                statusEl.textContent = 'AutoDJ';
                statusEl.className = 'np-status';
                trackEl.innerHTML = '<strong>Streaming</strong>';
            }
        }

        updateNowPlaying();
        setInterval(updateNowPlaying, 5000);

        player.on('error', () => {
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

# Create poster with purple theme
echo "[2/3] Creating poster..."
cat > /var/www/radio.peoplewelike.club/poster.svg <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1080" viewBox="0 0 1920 1080">
  <rect width="1920" height="1080" fill="#0d0d14"/>
  <text x="960" y="500" text-anchor="middle" font-family="Arial, sans-serif" font-size="48" fill="#a78bfa">People We Like Radio</text>
  <text x="960" y="580" text-anchor="middle" font-family="Arial, sans-serif" font-size="24" fill="#6b7280">Click to play</text>
</svg>
SVGEOF

if command -v ffmpeg &>/dev/null; then
    ffmpeg -y -i /var/www/radio.peoplewelike.club/poster.svg \
           -vf "scale=1920:1080" \
           /var/www/radio.peoplewelike.club/poster.jpg 2>/dev/null || true
fi
echo "    Created poster"

# Create error pages
echo "[3/3] Creating error pages..."
cat > /var/www/radio.peoplewelike.club/404.html <<'ERREOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 - People We Like Radio</title>
    <style>
        body {
            font-family: -apple-system, sans-serif;
            background: #0d0d14;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            margin: 0;
        }
        .error { text-align: center; }
        h1 { font-size: 4em; margin: 0; color: #a78bfa; }
        p { color: #6b7280; }
        a { color: #a78bfa; }
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
ERREOF

cat > /var/www/radio.peoplewelike.club/50x.html <<'ERREOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Error - People We Like Radio</title>
    <style>
        body {
            font-family: -apple-system, sans-serif;
            background: #0d0d14;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
            margin: 0;
        }
        .error { text-align: center; }
        h1 { font-size: 3em; margin: 0; color: #a78bfa; }
        p { color: #6b7280; }
        a { color: #a78bfa; }
    </style>
</head>
<body>
    <div class="error">
        <h1>Error</h1>
        <p>Something went wrong</p>
        <p><a href="/">Back to Radio</a></p>
    </div>
</body>
</html>
ERREOF
echo "    Created error pages"

# Set permissions
chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

echo ""
echo "=============================================="
echo "  Player Created"
echo "=============================================="
echo ""
echo "URL: https://radio.peoplewelike.club/"
echo ""
echo "Next step: Run ./09-finalize.sh"
