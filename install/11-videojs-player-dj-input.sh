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
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>People We Like Radio</title>

    <!-- Video.js 8 -->
    <link href="https://vjs.zencdn.net/8.10.0/video-js.css" rel="stylesheet">

    <style>
        /* ── CSS Variables ── */
        :root {
            --bg-dark:        #0d0a1a;
            --bg-card:        #1a1329;
            --purple:         #6b46c1;
            --purple-light:   #9f7aea;
            --purple-glow:    rgba(107, 70, 193, 0.4);
            --red-live:       #e53e3e;
            --red-glow:       rgba(229, 62, 62, 0.6);
            --green-ok:       #48bb78;
            --text:           #e2e8f0;
            --text-muted:     #a0aec0;
            --text-dim:       #718096;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI',
                         Roboto, Oxygen, Ubuntu, sans-serif;
            background: var(--bg-dark);
            color: var(--text);
            min-height: 100vh;
            overflow-x: hidden;
        }

        /* ── Background glow ── */
        .bg-glow {
            position: fixed; inset: 0; z-index: -1;
            background:
                radial-gradient(ellipse at 20% 80%, rgba(107,70,193,.12) 0%, transparent 50%),
                radial-gradient(ellipse at 80% 20%, rgba(159,122,234,.08) 0%, transparent 50%);
            transition: background 1s ease;
        }
        body.live-mode .bg-glow {
            background:
                radial-gradient(ellipse at 20% 80%, rgba(229,62,62,.10) 0%, transparent 50%),
                radial-gradient(ellipse at 80% 20%, rgba(229,62,62,.06) 0%, transparent 50%);
        }

        /* ── Layout ── */
        .page {
            max-width: 1060px;
            margin: 0 auto;
            padding: 20px;
            display: flex;
            flex-direction: column;
            min-height: 100vh;
        }

        header {
            text-align: center;
            padding: 30px 20px 20px;
        }
        .logo {
            font-size: 2em; font-weight: 700;
            background: linear-gradient(135deg, var(--purple-light), var(--purple));
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }
        body.live-mode .logo {
            background: linear-gradient(135deg, #fc8181, var(--red-live));
            -webkit-background-clip: text;
            background-clip: text;
        }
        .tagline {
            color: var(--text-dim);
            font-size: .85em;
            letter-spacing: 3px;
            text-transform: uppercase;
            margin-top: 4px;
        }

        /* ── Source indicator strip ── */
        .source-strip {
            display: flex;
            justify-content: center;
            gap: 12px;
            margin-bottom: 18px;
        }
        .source-option {
            display: flex; align-items: center; gap: 8px;
            padding: 8px 20px;
            border-radius: 24px;
            font-size: .8em; font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 1px;
            border: 1.5px solid transparent;
            opacity: .45;
            transition: all .4s ease;
        }
        .source-option.active {
            opacity: 1;
        }
        .source-option.autodj {
            border-color: rgba(107,70,193,.4);
            background: rgba(107,70,193,.12);
            color: var(--purple-light);
        }
        .source-option.autodj.active {
            border-color: var(--purple-light);
            background: rgba(107,70,193,.2);
            box-shadow: 0 0 18px var(--purple-glow);
        }
        .source-option.live {
            border-color: rgba(229,62,62,.4);
            background: rgba(229,62,62,.12);
            color: var(--red-live);
        }
        .source-option.live.active {
            border-color: var(--red-live);
            background: rgba(229,62,62,.2);
            box-shadow: 0 0 18px var(--red-glow);
            animation: liveGlow 1.6s ease-in-out infinite;
        }
        .source-dot {
            width: 8px; height: 8px;
            border-radius: 50%;
            background: currentColor;
        }
        .source-option.live.active .source-dot {
            animation: blink 1s infinite;
        }

        @keyframes liveGlow {
            0%,100% { box-shadow: 0 0 12px var(--red-glow); }
            50%     { box-shadow: 0 0 28px var(--red-glow), 0 0 48px rgba(229,62,62,.25); }
        }
        @keyframes blink {
            0%,100% { opacity: 1; }
            50%     { opacity: .25; }
        }

        /* ── Player card ── */
        .player-card {
            background: var(--bg-card);
            border-radius: 16px;
            overflow: hidden;
            box-shadow: 0 20px 60px rgba(0,0,0,.5);
            border: 1px solid rgba(107,70,193,.2);
            transition: border-color .5s, box-shadow .5s;
        }
        .player-card.live {
            border-color: rgba(229,62,62,.35);
            box-shadow: 0 20px 60px rgba(0,0,0,.5), 0 0 50px var(--red-glow);
        }

        /* ── Video wrapper ── */
        .video-area {
            position: relative;
            background: #000;
        }
        .video-js {
            width: 100%;
            aspect-ratio: 16/9;
        }

        /* ── Transition overlay (shown briefly during source switch) ── */
        .switch-overlay {
            position: absolute; inset: 0;
            display: flex; align-items: center; justify-content: center;
            flex-direction: column; gap: 14px;
            background: rgba(13,10,26,.85);
            opacity: 0;
            pointer-events: none;
            transition: opacity .4s ease;
            z-index: 20;
        }
        .switch-overlay.visible {
            opacity: 1;
        }
        .switch-overlay .spinner {
            width: 40px; height: 40px;
            border: 3px solid rgba(255,255,255,.15);
            border-top-color: var(--purple-light);
            border-radius: 50%;
            animation: spin .8s linear infinite;
        }
        body.live-mode .switch-overlay .spinner {
            border-top-color: var(--red-live);
        }
        .switch-overlay span {
            font-size: .9em; color: var(--text-muted);
        }
        @keyframes spin { to { transform: rotate(360deg); } }

        /* ── Now-playing bar ── */
        .now-playing {
            padding: 18px 22px;
            background: rgba(0,0,0,.3);
            display: flex; align-items: center; gap: 16px;
        }
        .np-icon {
            width: 48px; height: 48px;
            background: linear-gradient(135deg, var(--purple), var(--purple-light));
            border-radius: 12px;
            display: flex; align-items: center; justify-content: center;
            font-size: 22px; flex-shrink: 0;
        }
        body.live-mode .np-icon {
            background: linear-gradient(135deg, #c53030, var(--red-live));
        }
        .np-info { flex: 1; min-width: 0; }
        .np-label {
            font-size: .7em; text-transform: uppercase;
            letter-spacing: 2px; color: var(--text-dim);
            margin-bottom: 3px;
        }
        .np-title {
            font-size: 1.1em; font-weight: 600;
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }
        .np-artist {
            font-size: .9em; color: var(--text-muted);
            white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
        }

        /* ── Controls ── */
        .controls {
            padding: 14px 22px;
            display: flex; gap: 10px; flex-wrap: wrap;
            justify-content: center;
            border-top: 1px solid rgba(107,70,193,.1);
        }
        .btn {
            padding: 11px 20px; border: none; border-radius: 10px;
            font-size: .88em; font-weight: 600; cursor: pointer;
            transition: all .2s; display: flex; align-items: center; gap: 8px;
        }
        .btn-primary {
            background: linear-gradient(135deg, var(--purple), var(--purple-light));
            color: #fff;
        }
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px var(--purple-glow);
        }
        body.live-mode .btn-primary {
            background: linear-gradient(135deg, #c53030, var(--red-live));
        }
        body.live-mode .btn-primary:hover {
            box-shadow: 0 8px 24px var(--red-glow);
        }
        .btn-secondary {
            background: rgba(107,70,193,.12);
            color: var(--purple-light);
            border: 1px solid rgba(107,70,193,.25);
        }
        .btn-secondary:hover { background: rgba(107,70,193,.22); }
        .btn-secondary.active {
            background: rgba(107,70,193,.28);
            border-color: var(--purple-light);
        }

        /* ── Info bar ── */
        .info-bar {
            padding: 10px 22px;
            display: flex; justify-content: space-between; align-items: center;
            background: rgba(0,0,0,.2);
            font-size: .82em; color: var(--text-dim);
        }
        .source-label {
            display: flex; align-items: center; gap: 6px;
        }
        .source-label .dot {
            width: 7px; height: 7px; border-radius: 50%;
            background: var(--green-ok);
        }

        /* ── Footer ── */
        footer {
            text-align: center;
            padding: 30px 20px;
            color: var(--text-dim);
            font-size: .82em;
            margin-top: auto;
        }
        footer a { color: var(--purple-light); text-decoration: none; }

        /* ── Video.js theme overrides ── */
        .video-js .vjs-big-play-button {
            background: var(--purple); border: none; border-radius: 50%;
            width: 76px; height: 76px; line-height: 76px;
        }
        .video-js:hover .vjs-big-play-button { background: var(--purple-light); }
        body.live-mode .video-js .vjs-big-play-button { background: var(--red-live); }
        body.live-mode .video-js:hover .vjs-big-play-button { background: #fc8181; }
        .video-js .vjs-control-bar { background: rgba(13,10,26,.92); }
        .video-js .vjs-play-progress,
        .video-js .vjs-volume-level { background: var(--purple); }
        body.live-mode .video-js .vjs-play-progress,
        body.live-mode .video-js .vjs-volume-level { background: var(--red-live); }

        /* ── Responsive ── */
        @media (max-width: 640px) {
            .logo { font-size: 1.6em; }
            .now-playing { flex-direction: column; text-align: center; gap: 12px; }
            .np-info { width: 100%; }
            .source-strip { flex-direction: column; align-items: center; gap: 8px; }
        }
    </style>
</head>
<body>
    <div class="bg-glow"></div>

    <div class="page">
        <header>
            <div class="logo">People We Like</div>
            <div class="tagline">Radio</div>
        </header>

        <!-- Source indicator -->
        <div class="source-strip">
            <div class="source-option autodj active" id="src-autodj">
                <span class="source-dot"></span>
                Auto DJ
            </div>
            <div class="source-option live" id="src-live">
                <span class="source-dot"></span>
                Live DJ
            </div>
        </div>

        <!-- Player card -->
        <div class="player-card" id="player-card">
            <div class="video-area">
                <video
                    id="radio-player"
                    class="video-js vjs-big-play-centered"
                    controls
                    preload="auto"
                    poster="/poster.jpg">
                    <source src="/hls/current/index.m3u8" type="application/x-mpegURL">
                    <p class="vjs-no-js">
                        Enable JavaScript and use a modern browser to watch this stream.
                    </p>
                </video>

                <!-- Transition overlay -->
                <div class="switch-overlay" id="switch-overlay">
                    <div class="spinner"></div>
                    <span id="switch-text">Switching source...</span>
                </div>
            </div>

            <!-- Now playing -->
            <div class="now-playing">
                <div class="np-icon" id="np-icon">&#9835;</div>
                <div class="np-info">
                    <div class="np-label" id="np-label">Now Playing</div>
                    <div class="np-title" id="np-title">Connecting...</div>
                    <div class="np-artist" id="np-artist"></div>
                </div>
            </div>

            <!-- Controls -->
            <div class="controls">
                <button class="btn btn-primary" id="btn-play">Play</button>
                <button class="btn btn-secondary" id="btn-mute">Mute</button>
                <button class="btn btn-secondary" id="btn-fullscreen">Fullscreen</button>
            </div>

            <!-- Info bar -->
            <div class="info-bar">
                <div class="source-label">
                    <span class="dot" id="health-dot"></span>
                    <span id="source-text">Source: AutoDJ</span>
                </div>
                <div id="stream-quality">--</div>
            </div>
        </div>

        <footer>
            &copy; 2025 People We Like Radio |
            <a href="https://peoplewelike.club">peoplewelike.club</a>
        </footer>
    </div>

    <!-- Video.js 8 -->
    <script src="https://vjs.zencdn.net/8.10.0/video.min.js"></script>

    <script>
    (function () {
        'use strict';

        // ────────────────────────────────────────────
        // 1. Video.js initialisation
        //    Configured for live HLS with discontinuity
        //    support needed for AutoDJ ↔ Live switches.
        // ────────────────────────────────────────────
        var player = videojs('radio-player', {
            liveui: true,
            liveTracker: {
                trackingThreshold: 0,
                liveTolerance: 15
            },
            html5: {
                vhs: {
                    overrideNative: true,
                    smoothQualityChange: true,
                    allowSeeksWithinUnsafeLiveWindow: true,
                    handlePartialData: true,
                    experimentalBufferBasedABR: true
                },
                nativeAudioTracks: false,
                nativeVideoTracks: false
            },
            controls: true,
            autoplay: false,
            preload: 'auto',
            errorDisplay: false
        });

        // ────────────────────────────────────────────
        // 2. DOM references
        // ────────────────────────────────────────────
        var btnPlay       = document.getElementById('btn-play');
        var btnMute       = document.getElementById('btn-mute');
        var btnFullscreen = document.getElementById('btn-fullscreen');
        var npLabel       = document.getElementById('np-label');
        var npTitle       = document.getElementById('np-title');
        var npArtist      = document.getElementById('np-artist');
        var srcAutodj     = document.getElementById('src-autodj');
        var srcLive       = document.getElementById('src-live');
        var playerCard    = document.getElementById('player-card');
        var switchOverlay = document.getElementById('switch-overlay');
        var switchText    = document.getElementById('switch-text');
        var sourceText    = document.getElementById('source-text');
        var healthDot     = document.getElementById('health-dot');
        var qualityEl     = document.getElementById('stream-quality');

        // ────────────────────────────────────────────
        // 3. Player control buttons
        // ────────────────────────────────────────────
        btnPlay.addEventListener('click', function () {
            if (player.paused()) { player.play(); }
            else { player.pause(); }
        });
        player.on('play',  function () { btnPlay.textContent = 'Pause'; });
        player.on('pause', function () { btnPlay.textContent = 'Play'; });

        btnMute.addEventListener('click', function () {
            player.muted(!player.muted());
            btnMute.textContent = player.muted() ? 'Unmute' : 'Mute';
            btnMute.classList.toggle('active', player.muted());
        });

        btnFullscreen.addEventListener('click', function () {
            if (player.isFullscreen()) { player.exitFullscreen(); }
            else { player.requestFullscreen(); }
        });

        // ────────────────────────────────────────────
        // 4. Source tracking state
        // ────────────────────────────────────────────
        var currentMode       = 'autodj';   // 'autodj' | 'live'
        var switchInProgress  = false;
        var errorRecovering   = false;
        var POLL_INTERVAL     = 3000;       // 3 seconds
        var HLS_URL           = '/hls/current/index.m3u8';

        // ────────────────────────────────────────────
        // 5. UI update helpers
        // ────────────────────────────────────────────
        function setMode(mode) {
            var prev = currentMode;
            currentMode = mode;

            var isLive = (mode === 'live');

            // Body class drives CSS colour shifts
            document.body.classList.toggle('live-mode', isLive);

            // Source strip
            srcAutodj.classList.toggle('active', !isLive);
            srcLive.classList.toggle('active', isLive);

            // Player card border glow
            playerCard.classList.toggle('live', isLive);

            // Info bar
            sourceText.textContent = isLive ? 'Source: Live DJ' : 'Source: AutoDJ';
            healthDot.style.background = isLive ? 'var(--red-live)' : 'var(--green-ok)';

            // Show transition overlay briefly when source changes mid-playback
            if (prev !== mode && prev !== null && !player.paused()) {
                showSwitchOverlay(isLive ? 'Switching to Live DJ...' : 'Switching to AutoDJ...');
            }
        }

        function showSwitchOverlay(msg) {
            if (switchInProgress) return;
            switchInProgress = true;
            switchText.textContent = msg;
            switchOverlay.classList.add('visible');
            // Hide after 3 seconds (the relay inserts a discontinuity;
            // Video.js handles it, but there is a brief buffer pause)
            setTimeout(function () {
                switchOverlay.classList.remove('visible');
                switchInProgress = false;
            }, 3000);
        }

        // ────────────────────────────────────────────
        // 6. Now-playing poller
        //    Detects mode change from /api/nowplaying
        // ────────────────────────────────────────────
        function updateNowPlaying() {
            fetch('/api/nowplaying?' + Date.now())
                .then(function (r) { return r.json(); })
                .then(function (data) {
                    var mode = data.mode === 'live' ? 'live' : 'autodj';
                    setMode(mode);

                    if (mode === 'live') {
                        npLabel.textContent  = 'LIVE BROADCAST';
                        npTitle.textContent  = data.title  || 'LIVE SHOW';
                        npArtist.textContent = data.artist || '';
                    } else {
                        npLabel.textContent  = 'Now Playing';
                        npTitle.textContent  = data.title  || 'Unknown Track';
                        npArtist.textContent = data.artist || 'Unknown Artist';
                    }
                })
                .catch(function () {
                    // API down — keep current state, don't flash the UI
                });
        }

        updateNowPlaying();
        setInterval(updateNowPlaying, POLL_INTERVAL);

        // ────────────────────────────────────────────
        // 7. Quality display
        //    Shows resolution of the currently playing
        //    rendition once Video.js has decoded frames.
        // ────────────────────────────────────────────
        player.on('loadedmetadata', updateQuality);
        player.on('playing', updateQuality);

        function updateQuality() {
            var vw = player.videoWidth();
            var vh = player.videoHeight();
            if (vw && vh) {
                qualityEl.textContent = vw + 'x' + vh;
            }
        }

        // ────────────────────────────────────────────
        // 8. Error recovery
        //    HLS errors are expected during source
        //    switches (short gap while relay writes
        //    new segments). We retry automatically.
        // ────────────────────────────────────────────
        var ERROR_RETRY_DELAY = 3000;
        var MAX_RETRIES       = 5;
        var retryCount        = 0;

        player.on('error', function () {
            if (errorRecovering) return;
            errorRecovering = true;

            var err = player.error();
            console.warn('[radio] Player error:', err && err.message);

            if (retryCount >= MAX_RETRIES) {
                console.error('[radio] Max retries reached. Waiting for user action.');
                npTitle.textContent = 'Stream unavailable — click Play to retry';
                errorRecovering = false;
                retryCount = 0;
                return;
            }

            retryCount++;
            console.log('[radio] Retrying (' + retryCount + '/' + MAX_RETRIES + ')...');

            setTimeout(function () {
                player.src({ src: HLS_URL, type: 'application/x-mpegURL' });
                player.load();
                player.play().catch(function () {});
                errorRecovering = false;
            }, ERROR_RETRY_DELAY);
        });

        // Reset retry counter on successful playback
        player.on('playing', function () { retryCount = 0; });

        // ────────────────────────────────────────────
        // 9. Live edge seeking
        //    After a source switch (detected via
        //    discontinuity), seek to the live edge so
        //    the viewer stays real-time.
        // ────────────────────────────────────────────
        player.on('playing', function seekToLive() {
            try {
                var lt = player.liveTracker;
                if (lt && lt.isLive() && lt.behindLiveEdge()) {
                    lt.seekToLiveEdge();
                }
            } catch (e) { /* liveTracker may not be ready yet */ }
        });

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
echo "  - AutoDJ / Live DJ source strip indicator"
echo "  - Seamless switching via HLS discontinuity tags"
echo "  - Automatic error recovery (up to 5 retries)"
echo "  - Live edge seeking after source switch"
echo "  - Transition overlay animation during switch"
echo "  - /api/nowplaying polling every 3 seconds"
echo "  - Full theme shift (purple AutoDJ / red Live DJ)"
echo "  - Responsive down to 640px"
echo ""
echo "Player URL: https://radio.peoplewelike.club/"
echo ""
echo "Backend services required:"
echo "  systemctl status radio-switchd      # writes /run/radio/active"
echo "  systemctl status radio-hls-relay    # writes /hls/current/"
echo "  systemctl status liquidsoap-autodj  # AutoDJ audio"
echo "  systemctl status autodj-video-overlay  # FFmpeg video loop"
echo ""
