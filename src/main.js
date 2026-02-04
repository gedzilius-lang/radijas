import './style.css';

/* global videojs */
var BACKEND = import.meta.env.VITE_BACKEND_URL || '';
var HLS_URL = BACKEND + '/hls/current/index.m3u8';
var API_URL = BACKEND + '/api/nowplaying';

(function () {
    'use strict';

    var player = videojs('radio-player', {
        liveui: true,
        liveTracker: { trackingThreshold: 0, liveTolerance: 15 },
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
        controlBar: {
            playToggle: true,
            volumePanel: { inline: true },
            pictureInPictureToggle: true,
            fullscreenToggle: true,
            progressControl: true,
            liveDisplay: true,
            currentTimeDisplay: false,
            timeDivider: false,
            durationDisplay: false,
            remainingTimeDisplay: false
        },
        controls: true,
        autoplay: false,
        preload: 'auto',
        playsinline: true,
        errorDisplay: false,
        responsive: true,
        fluid: true,
        aspectRatio: '16:9'
    });

    player.src({ src: HLS_URL, type: 'application/x-mpegURL' });

    var npLabel = document.getElementById('np-label');
    var npTitle = document.getElementById('np-title');
    var npArtist = document.getElementById('np-artist');
    var npCountdown = document.getElementById('np-countdown');
    var srcProgram = document.getElementById('src-program');
    var srcLive = document.getElementById('src-live');
    var card = document.getElementById('card');
    var switchOverlay = document.getElementById('switch-overlay');
    var switchText = document.getElementById('switch-text');
    var currentMode = 'autodj';
    var switching = false;
    var recovering = false;
    var trackEnd = 0;

    function setMode(m) {
        var prev = currentMode;
        currentMode = m;
        var live = m === 'live';
        document.body.classList.toggle('live-mode', live);
        srcProgram.classList.toggle('active', !live);
        srcLive.classList.toggle('active', live);
        card.classList.toggle('live', live);
        if (prev !== m && prev !== null && !player.paused()) {
            showSwitch(live ? 'Switching to Live...' : 'Switching to Program...');
        }
    }

    function showSwitch(msg) {
        if (switching) return;
        switching = true;
        switchText.textContent = msg;
        switchOverlay.classList.add('visible');
        setTimeout(function () {
            switchOverlay.classList.remove('visible');
            switching = false;
        }, 3000);
    }

    function updateCountdown() {
        if (trackEnd <= 0) {
            npCountdown.textContent = currentMode === 'live' ? '' : '--:--';
            return;
        }
        var remaining = Math.max(0, Math.ceil((trackEnd - Date.now()) / 1000));
        var min = Math.floor(remaining / 60);
        var sec = remaining % 60;
        npCountdown.textContent = min + ':' + (sec < 10 ? '0' : '') + sec;
    }

    function poll() {
        fetch(API_URL + '?' + Date.now())
            .then(function (r) { return r.json(); })
            .then(function (d) {
                var m = d.mode === 'live' ? 'live' : 'autodj';
                setMode(m);
                if (m === 'live') {
                    npLabel.textContent = 'LIVE';
                    npTitle.textContent = d.title || 'LIVE';
                    npArtist.textContent = d.artist || '';
                    trackEnd = 0;
                } else {
                    npLabel.textContent = 'NOW PLAYING';
                    npTitle.textContent = d.title || 'Unknown Track';
                    npArtist.textContent = d.artist || 'Unknown Artist';
                    var dur = parseFloat(d.duration);
                    var sta = parseFloat(d.started_at);
                    if (dur > 0 && sta > 0) {
                        trackEnd = (sta + dur) * 1000;
                    } else {
                        trackEnd = 0;
                    }
                }
                updateCountdown();
            })
            .catch(function () {});
    }

    poll();
    setInterval(poll, 3000);
    setInterval(updateCountdown, 1000);

    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { poll(); }
    });

    var retries = 0;
    player.on('error', function () {
        if (recovering) return;
        recovering = true;
        if (retries >= 5) {
            npTitle.textContent = 'Stream unavailable';
            recovering = false;
            retries = 0;
            return;
        }
        retries++;
        setTimeout(function () {
            player.src({ src: HLS_URL, type: 'application/x-mpegURL' });
            player.load();
            player.play().catch(function () {});
            recovering = false;
        }, 3000);
    });

    player.on('playing', function () {
        retries = 0;
        try {
            var lt = player.liveTracker;
            if (lt && lt.isLive() && lt.behindLiveEdge()) {
                lt.seekToLiveEdge();
            }
        } catch (e) {}
    });

    var rt;
    function onRz() {
        clearTimeout(rt);
        rt = setTimeout(function () {
            player.dimensions(undefined, undefined);
        }, 200);
    }
    window.addEventListener('resize', onRz);
    window.addEventListener('orientationchange', onRz);

    var unlocked = false;
    document.addEventListener('touchstart', function u() {
        if (unlocked) return;
        unlocked = true;
        if (player.paused()) {
            var p = player.play();
            if (p && p.catch) p.catch(function () {});
        }
        document.removeEventListener('touchstart', u);
    }, { once: true, passive: true });
})();
