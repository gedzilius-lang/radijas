#!/usr/bin/env bash
###############################################################################
# CONFIGURE NGINX
# People We Like Radio Installation - Step 3
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Configuring Nginx"
echo "=============================================="

# Backup existing nginx config
echo "[1/7] Backing up existing nginx configuration..."
BACKUP_DIR="/root/backups/nginx-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/nginx/* "$BACKUP_DIR/" 2>/dev/null || true
echo "    Backed up to: $BACKUP_DIR"

# Load credentials
source /etc/radio/credentials

# Create RTMP configuration
echo "[2/7] Creating RTMP configuration..."
cat > /etc/nginx/rtmp.conf <<'RTMPEOF'
rtmp {
    server {
        listen 1935;
        chunk_size 4096;

        # Ping/pong for connection health
        ping 30s;
        ping_timeout 10s;

        # Live ingest application (external encoders publish here)
        application live {
            live on;

            # Authentication via on_publish callback
            on_publish http://127.0.0.1:8088/auth;

            # HLS output
            hls on;
            hls_path /var/www/hls/live;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;

            # Notify switch daemon on publish start/stop
            exec_publish /usr/local/bin/hls-switch live;
            exec_publish_done /usr/local/bin/hls-switch autodj;

            # Allow recording (optional)
            record off;
        }

        # Internal audio-only feed from Liquidsoap (localhost only)
        application autodj_audio {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny publish all;
            allow play 127.0.0.1;
            deny play all;
        }

        # AutoDJ combined video+audio output (localhost only)
        application autodj {
            live on;
            allow publish 127.0.0.1;
            deny publish all;

            hls on;
            hls_path /var/www/hls/autodj;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;
        }
    }
}
RTMPEOF
echo "    Created /etc/nginx/rtmp.conf"

# Create RTMP stats endpoint (internal only)
echo "[3/7] Creating RTMP stats endpoint..."
cat > /etc/nginx/conf.d/rtmp_stat.conf <<'STATEOF'
# RTMP Statistics endpoint (internal only)
server {
    listen 127.0.0.1:8089;

    location /rtmp_stat {
        rtmp_stat all;
        rtmp_stat_stylesheet /stat.xsl;
    }

    location /stat.xsl {
        root /var/www/html;
    }
}
STATEOF
echo "    Created /etc/nginx/conf.d/rtmp_stat.conf"

# Create RTMP authentication endpoint
echo "[4/7] Creating authentication endpoint..."
cat > /etc/nginx/conf.d/rtmp_auth.conf <<AUTHEOF
# RTMP Authentication endpoint (internal only)
server {
    listen 127.0.0.1:8088;

    location /auth {
        # Check stream key and password
        # Expected: ?name=STREAM_KEY&pwd=PASSWORD

        set \$auth_ok 0;

        # Check if stream key matches
        if (\$arg_name = "${STREAM_KEY}") {
            set \$auth_ok "\${auth_ok}1";
        }

        # Check if password matches
        if (\$arg_pwd = "${STREAM_PASSWORD}") {
            set \$auth_ok "\${auth_ok}1";
        }

        # Both must match (011)
        if (\$auth_ok = "011") {
            return 200;
        }

        # Authentication failed
        return 403;
    }
}
AUTHEOF
echo "    Created /etc/nginx/conf.d/rtmp_auth.conf"

# Create radio website virtual host
echo "[5/7] Creating radio.peoplewelike.club virtual host..."
cat > /etc/nginx/sites-available/radio.peoplewelike.club.conf <<'RADIOEOF'
# Radio website and HLS streaming
server {
    listen 80;
    server_name radio.peoplewelike.club stream.peoplewelike.club;

    root /var/www/radio.peoplewelike.club;
    index index.html;

    # HLS streaming location
    location /hls {
        alias /var/www/hls;

        # CORS headers for video.js
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, OPTIONS';
        add_header Access-Control-Allow-Headers 'Range,Content-Type';
        add_header Access-Control-Expose-Headers 'Content-Length,Content-Range';

        # Cache control for HLS segments
        location ~ \.m3u8$ {
            add_header Cache-Control "no-cache, no-store";
            add_header Access-Control-Allow-Origin *;
        }

        location ~ \.ts$ {
            add_header Cache-Control "max-age=86400";
            add_header Access-Control-Allow-Origin *;
        }

        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
    }

    # API: exact match for /api/nowplaying (player fetches without .json)
    location = /api/nowplaying {
        alias /var/www/radio/data/nowplaying;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }
    # API: prefix match for /api/*.json
    location /api/ {
        alias /var/www/radio/data/;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header Access-Control-Allow-Origin *;
    }

    # Static files
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Error pages
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
RADIOEOF
echo "    Created /etc/nginx/sites-available/radio.peoplewelike.club.conf"

# Enable radio site
ln -sf /etc/nginx/sites-available/radio.peoplewelike.club.conf /etc/nginx/sites-enabled/

# Include RTMP config in main nginx.conf if not already included
echo "[6/7] Updating main nginx.conf..."
if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf; then
    # Add RTMP include at the end of nginx.conf (outside http block)
    echo "" >> /etc/nginx/nginx.conf
    echo "# RTMP streaming" >> /etc/nginx/nginx.conf
    echo "include /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
    echo "    Added RTMP include to nginx.conf"
else
    echo "    RTMP include already present in nginx.conf"
fi

# Create stat.xsl for RTMP stats display
echo "[7/7] Creating RTMP stats stylesheet..."
cat > /var/www/html/stat.xsl <<'XSLEOF'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
<xsl:output method="html"/>
<xsl:template match="/">
<html>
<head><title>RTMP Statistics</title></head>
<body>
<h1>RTMP Statistics</h1>
<xsl:apply-templates select="rtmp"/>
</body>
</html>
</xsl:template>
<xsl:template match="rtmp">
<xsl:apply-templates select="server"/>
</xsl:template>
<xsl:template match="server">
<h2>Server</h2>
<xsl:apply-templates select="application"/>
</xsl:template>
<xsl:template match="application">
<h3>Application: <xsl:value-of select="name"/></h3>
<p>Clients: <xsl:value-of select="live/nclients"/></p>
</xsl:template>
</xsl:stylesheet>
XSLEOF
chmod 644 /var/www/html/stat.xsl

# Test nginx configuration
echo ""
echo "Testing nginx configuration..."
if nginx -t 2>&1; then
    echo ""
    echo -e "\033[0;32mNginx configuration test: PASSED\033[0m"
else
    echo ""
    echo -e "\033[0;31mNginx configuration test: FAILED\033[0m"
    echo "Check the error above and fix before continuing"
    exit 1
fi

echo ""
echo "=============================================="
echo "  Nginx Configuration Complete"
echo "=============================================="
echo ""
echo "Configuration files created:"
echo "  - /etc/nginx/rtmp.conf"
echo "  - /etc/nginx/conf.d/rtmp_stat.conf"
echo "  - /etc/nginx/conf.d/rtmp_auth.conf"
echo "  - /etc/nginx/sites-available/radio.peoplewelike.club.conf"
echo ""
echo "RTMP ingest endpoints:"
echo "  - rtmp://ingest.peoplewelike.club:1935/live"
echo ""
echo "HLS output endpoints:"
echo "  - https://radio.peoplewelike.club/hls/current/index.m3u8"
echo ""
echo "Next step: Run ./04-configure-liquidsoap.sh"
