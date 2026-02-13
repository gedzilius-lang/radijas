#!/usr/bin/env bash
###############################################################################
# FINALIZE INSTALLATION
# People We Like Radio Installation - Step 9 (Final)
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Finalizing Installation"
echo "=============================================="

# ============================================
# Pre-flight Checks
# ============================================
echo "[1/7] Running pre-flight checks..."

# Check if loop video exists
if [[ ! -f /var/lib/radio/loops/*.mp4 ]] 2>/dev/null; then
    echo ""
    echo "⚠️  WARNING: No video loop files found in /var/lib/radio/loops/"
    echo "    Upload at least one .mp4 file (1920x1080, 30fps, H.264) before starting"
    echo ""
    read -p "    Press Enter to continue anyway, or Ctrl+C to abort..."
fi

# Check if music files exist
MUSIC_COUNT=$(find /var/lib/radio/music -name "*.mp3" -o -name "*.MP3" 2>/dev/null | wc -l)
if [[ "$MUSIC_COUNT" -eq 0 ]]; then
    echo ""
    echo "⚠️  WARNING: No music files found in /var/lib/radio/music/"
    echo "    Upload .mp3 files before starting the radio"
    echo ""
    read -p "    Press Enter to continue anyway, or Ctrl+C to abort..."
else
    echo "    Found $MUSIC_COUNT music files"
fi

# ============================================
# Set Final Permissions
# ============================================
echo "[2/7] Setting final permissions..."

# HLS directories
chown -R www-data:www-data /var/www/hls
chmod -R 755 /var/www/hls

# Radio data
chown -R www-data:www-data /var/www/radio
chmod -R 755 /var/www/radio

# Radio website
chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

# Music library (writeable by liquidsoap and admin)
chown -R liquidsoap:audio /var/lib/radio/music
chmod -R 775 /var/lib/radio/music

# Video loops
chown -R radio:audio /var/lib/radio/loops
chmod -R 775 /var/lib/radio/loops

# Liquidsoap directories
chown -R liquidsoap:audio /var/lib/liquidsoap
chown -R liquidsoap:audio /var/log/liquidsoap

# Scripts
chmod +x /usr/local/bin/autodj-video-overlay
chmod +x /usr/local/bin/radio-switchd
chmod +x /usr/local/bin/hls-switch
chmod +x /usr/local/bin/radio-hls-relay
chmod +x /usr/local/bin/radio-nowplayingd
chmod +x /usr/local/bin/radio-ctl

echo "    Permissions set"

# ============================================
# Test nginx Configuration
# ============================================
echo "[3/7] Testing nginx configuration..."
if nginx -t 2>&1; then
    echo "    nginx config: OK"
else
    echo "    nginx config: FAILED"
    echo "    Fix configuration before continuing"
    exit 1
fi

# ============================================
# Start Services in Order
# ============================================
echo "[4/7] Starting services..."

# Restart nginx first
echo "    Starting nginx..."
systemctl restart nginx
sleep 2

# Start radio services in order
echo "    Starting liquidsoap-autodj..."
systemctl start liquidsoap-autodj || true
sleep 3

echo "    Starting autodj-video-overlay..."
systemctl start autodj-video-overlay || true
sleep 2

echo "    Starting radio-switchd..."
systemctl start radio-switchd || true
sleep 1

echo "    Starting radio-hls-relay..."
systemctl start radio-hls-relay || true
sleep 2

echo "    Starting radio-nowplayingd..."
systemctl start radio-nowplayingd || true
sleep 1

# ============================================
# Verify Services
# ============================================
echo "[5/7] Verifying services..."
echo ""

SERVICES="nginx liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay radio-nowplayingd"
ALL_OK=true

for svc in $SERVICES; do
    status=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    if [[ "$status" == "active" ]]; then
        echo "    ✓ $svc: running"
    else
        echo "    ✗ $svc: $status"
        ALL_OK=false
    fi
done

# ============================================
# Verify HLS Output
# ============================================
echo ""
echo "[6/7] Checking HLS output..."
sleep 5  # Give time for segments to generate

AUTODJ_SEGS=$(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)
CURRENT_SEGS=$(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)

echo "    AutoDJ segments: $AUTODJ_SEGS"
echo "    Current segments: $CURRENT_SEGS"

if [[ "$AUTODJ_SEGS" -gt 0 ]]; then
    echo "    ✓ AutoDJ is generating content"
else
    echo "    ⚠ AutoDJ not generating yet (may need music files)"
fi

# ============================================
# Display Final Summary
# ============================================
echo ""
echo "[7/7] Reading credentials..."
source /etc/radio/credentials

echo ""
echo "=============================================="
echo "  🎉 INSTALLATION COMPLETE!"
echo "=============================================="
echo ""
echo "════════════════════════════════════════════"
echo "  RADIO URLS"
echo "════════════════════════════════════════════"
echo ""
echo "  Player Page:"
echo "    https://radio.peoplewelike.club/"
echo ""
echo "  HLS Stream URL (for embedding):"
echo "    https://radio.peoplewelike.club/hls/current/index.m3u8"
echo ""
echo "════════════════════════════════════════════"
echo "  LIVE STREAMING CREDENTIALS"
echo "════════════════════════════════════════════"
echo ""
echo "  RTMP Server URL:"
echo "    rtmp://ingest.peoplewelike.club:1935/live"
echo ""
echo "  Stream Key:"
echo "    ${STREAM_KEY}"
echo ""
echo "  Password:"
echo "    ${STREAM_PASSWORD}"
echo ""
echo "  Full URL for encoder:"
echo "    rtmp://ingest.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}"
echo ""
echo "  Blackmagic Web Presenter Settings:"
echo "    Platform: Custom RTMP"
echo "    Server:   rtmp://ingest.peoplewelike.club:1935/live"
echo "    Key:      ${STREAM_KEY}?pwd=${STREAM_PASSWORD}"
echo ""
echo "════════════════════════════════════════════"
echo "  UPLOAD LOCATIONS"
echo "════════════════════════════════════════════"
echo ""
echo "  MUSIC FILES (.mp3):"
echo "    /var/lib/radio/music/"
echo "    ├── monday/morning/    (06:00-12:00)"
echo "    ├── monday/day/        (12:00-18:00)"
echo "    ├── monday/night/      (18:00-06:00)"
echo "    ├── tuesday/morning/   ..."
echo "    └── ... (all weekdays)"
echo "    └── default/           (fallback tracks)"
echo ""
echo "  VIDEO LOOPS (.mp4):"
echo "    /var/lib/radio/loops/"
echo "    (1920x1080, 30fps, H.264 - random rotation)"
echo ""
echo "════════════════════════════════════════════"
echo "  MANAGEMENT COMMANDS"
echo "════════════════════════════════════════════"
echo ""
echo "  radio-ctl start   - Start all services"
echo "  radio-ctl stop    - Stop all services"
echo "  radio-ctl restart - Restart all services"
echo "  radio-ctl status  - Check service status"
echo "  radio-ctl logs    - View live logs"
echo ""
echo "════════════════════════════════════════════"
echo ""

# Save summary to file
cat > /root/radio-info.txt <<INFOEOF
People We Like Radio - Installation Summary
============================================

RADIO URLS
----------
Player Page: https://radio.peoplewelike.club/
HLS Stream:  https://radio.peoplewelike.club/hls/current/index.m3u8

LIVE STREAMING CREDENTIALS
--------------------------
RTMP Server: rtmp://ingest.peoplewelike.club:1935/live
Stream Key:  ${STREAM_KEY}
Password:    ${STREAM_PASSWORD}
Full URL:    rtmp://ingest.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}

UPLOAD LOCATIONS
----------------
Music: /var/lib/radio/music/[weekday]/[morning|day|night]/
Loops: /var/lib/radio/loops/

MANAGEMENT
----------
radio-ctl start|stop|restart|status|logs

Generated: $(date)
INFOEOF
chmod 600 /root/radio-info.txt
echo "Summary saved to: /root/radio-info.txt"
echo ""

if [[ "$ALL_OK" == "true" ]]; then
    echo "✅ All services running. Your radio is ready!"
else
    echo "⚠️  Some services may need attention. Check logs with: radio-ctl logs"
fi
