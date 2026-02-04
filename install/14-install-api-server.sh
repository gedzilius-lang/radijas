#!/usr/bin/env bash
###############################################################################
# INSTALL RADIO API SERVER
# People We Like Radio Installation - Step 14
#
# Deploys a lightweight Python API server providing:
#   - Listener presence counting (heartbeat + count endpoints)
#   - Share snapshot creation with server-rendered OG tags
#   - OG image generation (1200x630 PNG)
#
# The server runs on 127.0.0.1:3000; nginx proxies to it.
#
# Run as root:
#   bash install/14-install-api-server.sh
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Installing Radio API Server"
echo "=============================================="

# ─────────────────────────────────────────────────
# 1. Deploy server script
# ─────────────────────────────────────────────────
echo "[1/4] Deploying radio_api.py..."
API_DIR="/opt/radio-api"
mkdir -p "$API_DIR"
cp "$(dirname "$0")/../server/radio_api.py" "$API_DIR/radio_api.py" 2>/dev/null \
  || cp /root/radijas/server/radio_api.py "$API_DIR/radio_api.py" 2>/dev/null \
  || { echo "ERROR: Cannot find server/radio_api.py"; exit 1; }
chmod 755 "$API_DIR/radio_api.py"
echo "    Installed to $API_DIR/radio_api.py"

# ─────────────────────────────────────────────────
# 2. Install SVG-to-PNG converter (for OG images)
# ─────────────────────────────────────────────────
echo "[2/4] Ensuring SVG converter is available..."
if ! command -v rsvg-convert &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq librsvg2-bin 2>/dev/null && echo "    Installed rsvg-convert" || echo "    rsvg-convert not available; will fall back to ffmpeg for OG images"
else
    echo "    rsvg-convert already installed"
fi

# ─────────────────────────────────────────────────
# 3. Create systemd service
# ─────────────────────────────────────────────────
echo "[3/4] Creating systemd service..."
cat > /etc/systemd/system/radio-api.service <<SVCEOF
[Unit]
Description=People We Like Radio API Server
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=www-data
Group=www-data
Environment=RADIO_API_PORT=3000
Environment=RADIO_BASE_URL=https://radio.peoplewelike.club
Environment=RADIO_DATA_DIR=/var/www/radio/data
ExecStart=/usr/bin/python3 $API_DIR/radio_api.py
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable radio-api
systemctl restart radio-api
echo "    Service radio-api enabled and started"

# ─────────────────────────────────────────────────
# 4. Add nginx proxy rules
# ─────────────────────────────────────────────────
echo "[4/4] Adding nginx proxy rules..."
NGINX_CONF="/etc/nginx/sites-available/radio.peoplewelike.club.conf"

if grep -q "api/listeners" "$NGINX_CONF" 2>/dev/null; then
    echo "    Proxy rules already present"
else
    # Insert proxy locations before the existing "location / {" block
    sed -i '/location \/ {/i\
    # Radio API server proxy\
    location /api/listeners/ {\
        proxy_pass http://127.0.0.1:3000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        add_header Access-Control-Allow-Origin *;\
    }\
\
    location /api/share/ {\
        proxy_pass http://127.0.0.1:3000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        add_header Access-Control-Allow-Origin *;\
    }\
\
    location /share/ {\
        proxy_pass http://127.0.0.1:3000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
    }\
\
    location /og/ {\
        proxy_pass http://127.0.0.1:3000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
    }' "$NGINX_CONF"
    echo "    Added proxy rules to nginx config"
fi

# Test and reload nginx
nginx -t && systemctl reload nginx
echo "    Nginx reloaded"

# ─────────────────────────────────────────────────
# Verify
# ─────────────────────────────────────────────────
sleep 1
if systemctl is-active --quiet radio-api; then
    echo ""
    echo "=============================================="
    echo "  Radio API Server Installed"
    echo "=============================================="
    echo ""
    echo "Endpoints (proxied via nginx):"
    echo "  POST /api/listeners/heartbeat  - Send listener heartbeat"
    echo "  GET  /api/listeners/count      - Get active listener count"
    echo "  POST /api/share/snapshot       - Create share snapshot"
    echo "  GET  /share/<id>               - Share page with OG tags"
    echo "  GET  /og/<id>.png              - OG image (1200x630)"
    echo ""
    echo "Service: systemctl status radio-api"
    echo ""
else
    echo ""
    echo "WARNING: radio-api service failed to start"
    echo "Check: journalctl -u radio-api -n 20"
fi
