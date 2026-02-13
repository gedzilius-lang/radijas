#!/usr/bin/env bash
###############################################################################
# CREATE SYSTEMD SERVICES
# People We Like Radio Installation - Step 6
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Creating Systemd Services"
echo "=============================================="

# ============================================
# 1. Liquidsoap AutoDJ Service
# ============================================
echo "[1/5] Creating liquidsoap-autodj service..."
cat > /etc/systemd/system/liquidsoap-autodj.service <<'LIQSVCEOF'
[Unit]
Description=Liquidsoap AutoDJ (audio-only) -> nginx-rtmp
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=liquidsoap
Group=audio
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/radio.liq
Restart=always
RestartSec=3
Nice=10

# Security hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

# Allow access to required paths
ReadWritePaths=/var/lib/liquidsoap /var/www/radio/data /var/log/liquidsoap

# Environment
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target
LIQSVCEOF

# Create override for restart behavior
mkdir -p /etc/systemd/system/liquidsoap-autodj.service.d
cat > /etc/systemd/system/liquidsoap-autodj.service.d/override.conf <<'LIQOVERRIDEEOF'
[Service]
Restart=always
RestartSec=3
TimeoutStopSec=10
KillSignal=SIGINT
LIQOVERRIDEEOF
echo "    Created liquidsoap-autodj.service"

# ============================================
# 2. AutoDJ Video Overlay Service
# ============================================
echo "[2/5] Creating autodj-video-overlay service..."
cat > /etc/systemd/system/autodj-video-overlay.service <<'OVERLAYSVCEOF'
[Unit]
Description=AutoDJ Video Overlay: loop MP4 + AutoDJ audio -> nginx-rtmp autodj
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/autodj-video-overlay
Restart=always
RestartSec=3
KillSignal=SIGINT
TimeoutStopSec=10

# Environment
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=multi-user.target
OVERLAYSVCEOF
echo "    Created autodj-video-overlay.service"

# ============================================
# 3. Radio Switch Daemon Service
# ============================================
echo "[3/5] Creating radio-switchd service..."
cat > /etc/systemd/system/radio-switchd.service <<'SWITCHSVCEOF'
[Unit]
Description=Radio switch daemon (LIVE <-> AutoDJ) every 1s
After=nginx.service
Wants=nginx.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-switchd
Restart=always
RestartSec=1

# Create runtime directory
RuntimeDirectory=radio
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
SWITCHSVCEOF
echo "    Created radio-switchd.service"

# ============================================
# 4. Radio HLS Relay Service
# ============================================
echo "[4/5] Creating radio-hls-relay service..."
cat > /etc/systemd/system/radio-hls-relay.service <<'RELAYSVCEOF'
[Unit]
Description=Radio HLS relay (stable /hls/current playlist for seamless switching)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1

# State directory
StateDirectory=radio-hls-relay
StateDirectoryMode=0755

[Install]
WantedBy=multi-user.target
RELAYSVCEOF
echo "    Created radio-hls-relay.service"

# ============================================
# 5. Radio Now-Playing Daemon Service
# ============================================
echo "[5/6] Creating radio-nowplayingd service..."
cat > /etc/systemd/system/radio-nowplayingd.service <<'NPSVCEOF'
[Unit]
Description=Radio now-playing metadata daemon (reads Liquidsoap log, writes JSON)
After=liquidsoap-autodj.service radio-switchd.service
Wants=liquidsoap-autodj.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/radio-nowplayingd
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
NPSVCEOF
echo "    Created radio-nowplayingd.service"

# ============================================
# 6. Runtime Directory tmpfiles
# ============================================
echo "[6/6] Creating tmpfiles configuration..."
cat > /etc/tmpfiles.d/radio.conf <<'TMPFILESEOF'
# Radio runtime directories
d /run/radio 0755 root root -
d /var/lib/radio-hls-relay 0755 root root -
TMPFILESEOF
echo "    Created /etc/tmpfiles.d/radio.conf"

# Create directories now
systemd-tmpfiles --create /etc/tmpfiles.d/radio.conf 2>/dev/null || true

# ============================================
# Reload systemd
# ============================================
echo ""
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable services (but don't start yet)
echo "Enabling services..."
systemctl enable liquidsoap-autodj.service
systemctl enable autodj-video-overlay.service
systemctl enable radio-switchd.service
systemctl enable radio-hls-relay.service
systemctl enable radio-nowplayingd.service

echo ""
echo "=============================================="
echo "  Systemd Services Created"
echo "=============================================="
echo ""
echo "Services installed:"
echo "  - liquidsoap-autodj.service    (Liquidsoap audio engine)"
echo "  - autodj-video-overlay.service (FFmpeg video overlay)"
echo "  - radio-switchd.service        (Live/AutoDJ switch daemon)"
echo "  - radio-hls-relay.service      (Seamless HLS relay)"
echo "  - radio-nowplayingd.service    (Now-playing metadata daemon)"
echo ""
echo "Startup order:"
echo "  1. nginx"
echo "  2. liquidsoap-autodj"
echo "  3. autodj-video-overlay"
echo "  4. radio-switchd"
echo "  5. radio-hls-relay"
echo "  6. radio-nowplayingd"
echo ""
echo "Management commands:"
echo "  radio-ctl start   - Start all services"
echo "  radio-ctl stop    - Stop all services"
echo "  radio-ctl status  - Check service status"
echo "  radio-ctl logs    - View live logs"
echo ""
echo "Next step: Run ./07-setup-ssl.sh"
