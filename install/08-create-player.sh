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
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>People We Like Radio</title>
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }

        html, body {
            width: 100%;
            height: 100%;
            overflow-x: hidden;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #0d0d14;
            min-height: 100vh;
            min-height: 100dvh;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            color: #fff;
            padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
        }

        .player-wrap {
            width: 100%;
            max-width: 1200px;
            padding: clamp(10px, 3vw, 30px);
        }

        h1 {
            text-align: center;
            font-size: clamp(1.1em, 4vw, 1.8em);
            font-weight: 400;
            margin-bottom: clamp(12px, 3vw, 24px);
            color: #a78bfa;
        }

        .video-container {
            position: relative;
            background: #1a1a24;
            border-radius: clamp(8px, 2vw, 16px);
            overflow: hidden;
            box-shadow: 0 0 60px rgba(167, 139, 250, 0.15);
        }

        .video-js {
            width: 100%;
            height: auto;
            aspect-ratio: 16/9;
        }

        /* Video.js purple theme */
        .video-js .vjs-big-play-button {
            background: rgba(167, 139, 250, 0.9);
            border: none;
            border-radius: 50%;
            width: clamp(50px, 12vw, 80px);
            height: clamp(50px, 12vw, 80px);
            line-height: clamp(50px, 12vw, 80px);
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: clamp(1.5em, 4vw, 2em);
        }
        .video-js .vjs-big-play-button:hover,
        .video-js .vjs-big-play-button:focus {
            background: #a78bfa;
        }
        .video-js .vjs-control-bar {
            background: rgba(13, 13, 20, 0.95);
            height: clamp(35px, 8vw, 45px);
        }
        .video-js .vjs-play-progress,
        .video-js .vjs-volume-level {
            background: #a78bfa;
        }
        .video-js .vjs-slider {
            background: rgba(167, 139, 250, 0.3);
        }
        .video-js .vjs-time-control {
            font-size: clamp(0.7em, 2vw, 1em);
            padding: 0 0.5em;
            min-width: auto;
        }

        .now-playing {
            display: flex;
            align-items: center;
            gap: clamp(8px, 2vw, 16px);
            padding: clamp(12px, 3vw, 20px);
            background: #13131a;
            border-top: 1px solid #252530;
        }

        .np-icon {
            width: clamp(36px, 8vw, 48px);
            height: clamp(36px, 8vw, 48px);
            background: linear-gradient(135deg, #7c3aed, #a78bfa);
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: clamp(1em, 3vw, 1.4em);
            flex-shrink: 0;
        }

        .np-info {
            flex: 1;
            min-width: 0;
            display: flex;
            flex-direction: column;
            gap: 4px;
        }

        .np-label {
            font-size: clamp(0.65em, 1.8vw, 0.75em);
            text-transform: uppercase;
            letter-spacing: 1px;
            color: #6b7280;
        }

        .np-title {
            font-size: clamp(0.9em, 2.5vw, 1.1em);
            font-weight: 500;
            color: #fff;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .np-artist {
            font-size: clamp(0.8em, 2vw, 0.95em);
            color: #9ca3af;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .np-status {
            padding: clamp(4px, 1vw, 6px) clamp(8px, 2vw, 12px);
            border-radius: 4px;
            font-size: clamp(0.6em, 1.5vw, 0.7em);
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            background: #7c3aed;
            flex-shrink: 0;
            align-self: flex-start;
        }
        .np-status.live {
            background: #dc2626;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.6; }
        }

        /* Tablet */
        @media (max-width: 768px) {
            .now-playing {
                flex-wrap: wrap;
            }
            .np-status {
                order: -1;
                margin-bottom: 4px;
            }
        }

        /* Mobile */
        @media (max-width: 480px) {
            body {
                justify-content: flex-start;
                padding-top: clamp(20px, 5vh, 60px);
            }
            .now-playing {
                flex-direction: column;
                align-items: flex-start;
                gap: 8px;
            }
            .np-icon {
                display: none;
            }
            .np-info {
                width: 100%;
            }
            .np-title, .np-artist {
                white-space: normal;
                word-break: break-word;
            }
        }

        /* Landscape mobile */
        @media (max-height: 500px) and (orientation: landscape) {
            body {
                justify-content: center;
            }
            h1 {
                margin-bottom: 8px;
                font-size: 1em;
            }
            .player-wrap {
                max-width: 90vh;
            }
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
                playsinline
                preload="auto"
                poster="/poster.jpg">
                <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
            </video>
            <div class="now-playing">
                <div class="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Ready to play</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
                <div class="np-status" id="np-status">Program</div>
            </div>
        </div>
    </div>

    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>
    <script>
        const player = videojs('player', {
            liveui: true,
            fluid: true,
            responsive: true,
            html5: {
                vhs: {
                    overrideNative: true,
                    smoothQualityChange: true
                },
                nativeAudioTracks: false,
                nativeVideoTracks: false
            }
        });

        const npLabel = document.getElementById('np-label');
        const npTitle = document.getElementById('np-title');
        const npArtist = document.getElementById('np-artist');
        const npStatus = document.getElementById('np-status');

        function parseFilename(filename) {
            // Remove extension and path
            let name = filename.replace(/^.*[\\/]/, '').replace(/\.[^.]+$/, '');
            // Try to split "Artist - Title" format
            const parts = name.split(' - ');
            if (parts.length >= 2) {
                return { artist: parts[0].trim(), title: parts.slice(1).join(' - ').trim() };
            }
            // Try underscore format "Artist_-_Title"
            const uparts = name.split('_-_');
            if (uparts.length >= 2) {
                return { artist: uparts[0].replace(/_/g, ' ').trim(), title: uparts.slice(1).join(' - ').replace(/_/g, ' ').trim() };
            }
            return { artist: '', title: name.replace(/_/g, ' ') };
        }

        async function updateNowPlaying() {
            try {
                const res = await fetch('/api/nowplaying?t=' + Date.now());
                if (!res.ok) throw new Error('API error');
                const data = await res.json();

                if (data.mode === 'live') {
                    npLabel.textContent = 'LIVE BROADCAST';
                    npTitle.textContent = data.title || 'Live Show';
                    npArtist.textContent = data.artist || '';
                    npStatus.textContent = 'LIVE';
                    npStatus.className = 'np-status live';
                } else {
                    npLabel.textContent = 'Now Playing';
                    npStatus.textContent = 'Program';
                    npStatus.className = 'np-status';

                    // Try sources in order: metadata, filename parsing
                    let title = data.title;
                    let artist = data.artist;

                    // If no proper metadata, try parsing filename
                    if ((!title || title === 'Unknown' || title === '') && data.filename) {
                        const parsed = parseFilename(data.filename);
                        title = parsed.title;
                        artist = parsed.artist;
                    }

                    // Display artist - title format
                    if (artist && title) {
                        npArtist.textContent = artist;
                        npTitle.textContent = title;
                    } else if (title) {
                        npTitle.textContent = title;
                        npArtist.textContent = '';
                    } else {
                        npTitle.textContent = 'Unknown Track';
                        npArtist.textContent = '';
                    }
                }
            } catch (e) {
                // API unavailable - keep last known state or show default
                if (npTitle.textContent === 'Ready to play') {
                    npLabel.textContent = 'Now Playing';
                    npTitle.textContent = 'Connecting...';
                    npArtist.textContent = '';
                }
                npStatus.textContent = 'Program';
                npStatus.className = 'np-status';
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
