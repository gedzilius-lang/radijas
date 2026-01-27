#!/usr/bin/env bash
###############################################################################
# CREATE DIRECTORY STRUCTURE
# People We Like Radio Installation - Step 2
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Creating Directory Structure"
echo "=============================================="

# Define stream credentials (CHANGE THESE!)
STREAM_KEY="pwl-live-2024"
STREAM_PASSWORD="R4d10L1v3Str34m!"

# Save credentials to secure file
echo "[1/6] Saving stream credentials..."
mkdir -p /etc/radio
cat > /etc/radio/credentials <<EOF
# People We Like Radio - Stream Credentials
# Keep this file secure!
STREAM_KEY=${STREAM_KEY}
STREAM_PASSWORD=${STREAM_PASSWORD}

# RTMP Ingest URL:
# rtmp://ingest.peoplewelike.club:1935/live
#
# Stream Key: ${STREAM_KEY}
# Password: ${STREAM_PASSWORD}
#
# Full URL for encoder:
# rtmp://ingest.peoplewelike.club:1935/live/${STREAM_KEY}?pwd=${STREAM_PASSWORD}
EOF
chmod 600 /etc/radio/credentials
echo "    Credentials saved to /etc/radio/credentials"

# HLS directories
echo "[2/6] Creating HLS directories..."
mkdir -p /var/www/hls/{autodj,live,current,placeholder}
chown -R www-data:www-data /var/www/hls
chmod -R 755 /var/www/hls

echo "    /var/www/hls/autodj    - AutoDJ HLS output"
echo "    /var/www/hls/live      - Live stream HLS output"
echo "    /var/www/hls/current   - Relay output (served to players)"
echo "    /var/www/hls/placeholder - Placeholder content"

# Music library with schedule-based folders
echo "[3/6] Creating music library structure..."
MUSIC_ROOT="/var/lib/radio/music"
mkdir -p "$MUSIC_ROOT"

# Create weekday + dayphase folders
for day in monday tuesday wednesday thursday friday saturday sunday; do
    for phase in morning day night; do
        mkdir -p "${MUSIC_ROOT}/${day}/${phase}"
    done
done

# Create a default/fallback folder
mkdir -p "${MUSIC_ROOT}/default"

chown -R liquidsoap:audio "$MUSIC_ROOT"
chmod -R 775 "$MUSIC_ROOT"

echo "    Created schedule-based music folders:"
echo "    ${MUSIC_ROOT}/"
echo "    ├── monday/   (morning, day, night)"
echo "    ├── tuesday/  (morning, day, night)"
echo "    ├── wednesday/(morning, day, night)"
echo "    ├── thursday/ (morning, day, night)"
echo "    ├── friday/   (morning, day, night)"
echo "    ├── saturday/ (morning, day, night)"
echo "    ├── sunday/   (morning, day, night)"
echo "    └── default/  (fallback when scheduled folder empty)"

# Video loops directory
echo "[4/6] Creating video loops directory..."
mkdir -p /var/lib/radio/loops
chown -R radio:audio /var/lib/radio/loops
chmod -R 775 /var/lib/radio/loops

echo "    /var/lib/radio/loops - Upload .mp4 loop files here"
echo "    (1920x1080, 30fps, H.264, will randomly rotate)"

# Liquidsoap directories
echo "[5/6] Creating Liquidsoap directories..."
mkdir -p /var/lib/liquidsoap
mkdir -p /var/log/liquidsoap
mkdir -p /etc/liquidsoap
mkdir -p /var/www/radio/data

chown -R liquidsoap:audio /var/lib/liquidsoap
chown -R liquidsoap:audio /var/log/liquidsoap
chown -R liquidsoap:audio /etc/liquidsoap
chown -R www-data:www-data /var/www/radio

chmod -R 775 /var/lib/liquidsoap
chmod -R 775 /var/log/liquidsoap
chmod 755 /etc/liquidsoap
chmod -R 755 /var/www/radio

# Runtime directories
echo "[6/6] Creating runtime directories..."
mkdir -p /run/radio
mkdir -p /var/lib/radio-hls-relay

chown -R radio:radio /run/radio
chown -R radio:radio /var/lib/radio-hls-relay
chmod -R 755 /run/radio
chmod -R 755 /var/lib/radio-hls-relay

# Create radio web root (separate from av.peoplewelike.club)
mkdir -p /var/www/radio.peoplewelike.club
chown -R www-data:www-data /var/www/radio.peoplewelike.club
chmod -R 755 /var/www/radio.peoplewelike.club

echo ""
echo "=============================================="
echo "  Directory Structure Created"
echo "=============================================="
echo ""
echo "UPLOAD LOCATIONS:"
echo ""
echo "  MUSIC FILES (.mp3):"
echo "  └── /var/lib/radio/music/"
echo "      ├── monday/morning/    (06:00-12:00)"
echo "      ├── monday/day/        (12:00-18:00)"
echo "      ├── monday/night/      (18:00-06:00)"
echo "      ├── tuesday/morning/   ..."
echo "      └── ... (same for all weekdays)"
echo "      └── default/           (fallback tracks)"
echo ""
echo "  VIDEO LOOPS (.mp4):"
echo "  └── /var/lib/radio/loops/"
echo "      └── *.mp4 (1920x1080, 30fps, H.264)"
echo ""
echo "  Day phases:"
echo "    morning: 06:00 - 12:00"
echo "    day:     12:00 - 18:00"
echo "    night:   18:00 - 06:00"
echo ""
echo "Next step: Run ./03-configure-nginx.sh"
