Project Handoff: People We Like Radio (AutoDJ + Live) – Backend Architecture & Lessons
0) Goal (what we needed)
We needed a single public HLS endpoint that:
Plays AutoDJ 24/7 (audio + MP4 loop overlay, plus metadata / now-playing)
Allows live RTMP ingest (Blackmagic/OBS/etc.)
Switches automatically between Live and AutoDJ with no page refresh
Recovers from failures automatically (services restart, health checks, avoids dead playlists)
Keeps the frontend simple: it should always load one HLS URL and never need to “know” which source is active.
The key requirement that made this tricky:
switching must happen in the same player session, not requiring user refresh.

1) High-level design (what’s running)
We operate two independent HLS “source” outputs and then provide a third, stable “relay” playlist used by the website:
Sources
AutoDJ HLS
Generated from: liquidsoap (audio-only) + ffmpeg overlay (video loop + audio)
Published as RTMP into nginx-rtmp (application autodj)
nginx-rtmp writes HLS segments to:
/var/www/hls/autodj/index.m3u8
/var/www/hls/autodj/index-*.ts
Live HLS
Ingest via RTMP application live (Blackmagic/OBS pushes to it)
nginx-rtmp writes HLS segments to:
/var/www/hls/live/index.m3u8
/var/www/hls/live/index-*.ts
Public “Stable” Output
Relay HLS (the real “/hls/current” you serve)
A daemon (radio-hls-relay) continuously builds a stable playlist:
/var/www/hls/current/index.m3u8
/var/www/hls/current/seg-*.ts symlinks
The website points to:
https://radio.peoplewelike.club/hls/current/index.m3u8
This relay layer is what makes switching seamless without refresh.

2) Why the relay exists (the big problem we hit)
What didn’t work
Originally we tried switching by changing a symlink:
/var/www/hls/current → either /var/www/hls/autodj or /var/www/hls/live
This can work, but in real browsers it often doesn’t switch cleanly because:
HLS players cache playlist/segments
Segment numbering resets (index-0.ts on new stream) causing confusion
Discontinuity boundaries were inconsistent
When switching, the player may request old segments that no longer exist
It “works only after refresh” because the browser resets its HLS state.
What solved it
We introduced a “relay” playlist generator:
It assigns monotonic segment numbers (seg-<seq>.ts) regardless of source
It inserts #EXT-X-DISCONTINUITY when the source changes
It maintains a stable window (e.g., last 10 segments) to avoid stale requests
The player always sees a continuous timeline and adapts smoothly.
This is the single most important architectural decision.

3) Nginx RTMP configuration (current working state)
File: /etc/nginx/rtmp.conf
Key points:
RTMP listens on 1935
application live writes HLS to /var/www/hls/live
application autodj writes HLS to /var/www/hls/autodj
application autodj_audio is internal-only audio feed for overlay
You currently have:
rtmp {
  server {
    listen 1935;
    chunk_size 4096;

    application live {
      live on;

      hls on;
      hls_path /var/www/hls/live;
      hls_fragment 6s;
      hls_playlist_length 120s;
      hls_cleanup on;
      hls_continuous on;

      exec_publish /usr/local/bin/hls-switch live;
      exec_publish_done /usr/local/bin/hls-switch autodj;
    }

    application autodj_audio {
      live on;
      record off;
      allow publish 127.0.0.1;
      deny  publish all;
      allow play 127.0.0.1;
      deny  play all;
    }

    application autodj {
      live on;
      allow publish 127.0.0.1;
      deny publish all;

      hls on;
      hls_path /var/www/hls/autodj;
      hls_fragment 6;
      hls_playlist_length 120;
      hls_cleanup on;
      hls_continuous on;
    }
  }
}

Note:
We initially broke nginx by adding stat all; in the wrong context and without ensuring module support. We later corrected this once the nginx-rtmp build supported it.

4) RTMP stats endpoint (for live detection)
We needed a reliable way to know if live ingest is present, not just “segments exist”.
We enabled RTMP stats and exposed it on localhost:
http://127.0.0.1:8089/rtmp_stat
Config: /etc/nginx/conf.d/rtmp_stat.conf
Verified it returns XML with <application><name>live</name> and <nclients>.
This is used by radio-switchd to decide if live is truly active.

5) Systemd services (what runs the system)
5.1 AutoDJ audio (Liquidsoap)
Service: /etc/systemd/system/liquidsoap-autodj.service
Runs: /usr/bin/liquidsoap /etc/liquidsoap/radio.liq
User/Group: liquidsoap
Restart hardening enabled
ReadWritePaths include /var/lib/liquidsoap and /var/www/radio/data
This produces:
audio feed to RTMP autodj_audio (internal)
now-playing data somewhere under /var/www/radio/data (depends on your liq config)
5.2 AutoDJ overlay publisher (FFmpeg)
Service: /etc/systemd/system/autodj-video-overlay.service
Exec: /usr/local/bin/autodj-video-overlay
This script:
loops MP4 from /var/lib/liquidsoap/loop.mp4
pulls audio from rtmp://127.0.0.1:1935/autodj_audio/stream?live=1
publishes combined audio+video to rtmp://127.0.0.1:1935/autodj/index
Key technical details:
fixed FPS = 25
GOP aligned to fragment size (6s → GOP=150)
forces keyframes every 6s
repeat-headers=1 ensures SPS/PPS at keyframes (important for browser HLS stability)
constant-ish bitrate to keep segments consistent
This was critical for “always works” HLS playback.
5.3 Switching decision daemon
Service: /etc/systemd/system/radio-switchd.service
Exec: /usr/local/bin/radio-switchd
radio-switchd runs every 1s and writes the current “active source” to:
/run/radio/active containing live or autodj
Its decision logic:
Live is healthy if:
live HLS playlist exists AND contains .ts lines
latest .ts exists on disk
AND either:
RTMP stats show nclients > 0, OR
playlist mtime is “fresh” (<= 8 seconds)
Otherwise active = autodj
This avoids false switching when live playlist exists but ingest has stopped.
5.4 HLS relay (the seamless switching output)
Service: /etc/systemd/system/radio-hls-relay.service
Exec: /usr/local/bin/radio-hls-relay
This Python daemon is the core of seamless playback.
It:
watches /run/radio/active
reads source playlist /var/www/hls/{live|autodj}/index.m3u8
takes last N segments (window size = 10)
creates monotonic segment IDs and symlinks:
/var/www/hls/current/seg-<seq>.ts → source file
writes /var/www/hls/current/index.m3u8 with:
stable #EXT-X-MEDIA-SEQUENCE
correct target duration
#EXT-X-DISCONTINUITY when switching sources
This is why the player switches without refresh.

6) Utility script: hls-switch (legacy + safety)
File: /usr/local/bin/hls-switch
This is still referenced in nginx-rtmp exec_publish hooks.
It switches /var/www/hls/current symlink to live/autodj, but now the relay is the real “public truth”.
Important: the relay uses /var/www/hls/current as a directory, not just a symlink.
If both exist, the relay’s OUT_DIR=/var/www/hls/current needs to be a directory.
So effectively, the relay replaced symlink switching as the public mechanism.
If you keep hls-switch, ensure it does not fight radio-hls-relay. In the final working flow, radio-hls-relay is the correct layer for client consumption.

7) Major issues we hit (and what fixed them)
Issue A: Player “loading forever” after switching
Cause:
direct symlink switching produced segment numbering resets and stale segment requests
Fix:
introduced radio-hls-relay with monotonic seg numbering + discontinuity tags
Issue B: 404s for placeholder segments
Cause:
playlist referenced placeholder.ts in paths where the file didn’t exist
Fix:
ensured placeholder assets exist where referenced (e.g. live placeholder symlink)
reduced reliance on placeholder by ensuring AutoDJ is always running and relay always has segments
Issue C: Nginx config failures (“location not allowed here”, “unknown directive stat”)
Cause:
injected config snippets into wrong include context
added RTMP stat directive without verifying module availability and correct placement
Fix:
moved RTMP stat HTTP endpoint into a valid server {} inside /etc/nginx/conf.d/rtmp_stat.conf
ensured RTMP stat directive exists only where supported
validated with nginx -t every change
Issue D: Blackmagic encoder “growing cache”, ingest not accepted
Cause:
port 1935 reachable but application/key mismatch or server not writing HLS correctly yet
Fix:
confirmed local publish works with:
ffmpeg ... rtmp://127.0.0.1:1935/live/index
validated HLS output exists in /var/www/hls/live
RTMP stats helped confirm ingest presence
Issue E: Frontend didn’t update after index.html change
Cause:
caching (browser / CDN) and/or patch not actually in served file
Fix:
verified using curl with cache-busters
ensured we edited /var/www/radio/index.html (correct served path)
inserted PWL_UI_* markers for deterministic verification

8) How to operate / debug (for new dev)
Check service health
systemctl is-active liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay
journalctl -u liquidsoap-autodj -f
journalctl -u autodj-video-overlay -f
journalctl -u radio-switchd -f
journalctl -u radio-hls-relay -f

Check live ingest detection
curl -fsS http://127.0.0.1:8089/rtmp_stat | grep -A3 '<name>live</name>'

Check current public playlist
curl -fsS https://radio.peoplewelike.club/hls/current/index.m3u8 | head -n 30
ls -la /var/www/hls/current | head

Confirm source playlists
ls -la /var/www/hls/autodj | head
ls -la /var/www/hls/live | head


9) What not to break (critical invariants)
The public player must always point to the relay playlist
/hls/current/index.m3u8 should be stable
GOP and keyframe cadence must match fragment duration
currently 6s fragments, keyframes forced every 6s
this is a big reason switching is smooth
Overlay path assumptions
MP4 loop: /var/lib/liquidsoap/loop.mp4
audio RTMP feed: rtmp://127.0.0.1:1935/autodj_audio/stream?live=1
combined publish: rtmp://127.0.0.1:1935/autodj/index
Switch logic must be based on both playlist freshness and RTMP nclients
relying on only file existence is not enough

10) Summary (one paragraph)
We built a dual-source streaming system (AutoDJ and Live) using nginx-rtmp for HLS segment generation, liquidsoap for continuous audio and metadata, and ffmpeg to generate a stable MP4-overlay video stream. The main challenge was seamless switching without page refresh: direct symlink switching caused HLS players to stall due to cached segments and sequence resets. The fix was a relay daemon that generates a stable “current” playlist with monotonic segment IDs and discontinuity markers, driven by a switch daemon that detects live availability using both RTMP stats and playlist freshness. The result is a 24/7 station that automatically switches between live and autodj reliably while keeping the frontend locked to a single HLS URL.
