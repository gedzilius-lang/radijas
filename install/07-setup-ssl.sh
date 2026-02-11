#!/usr/bin/env bash
###############################################################################
# SETUP SSL CERTIFICATES
# People We Like Radio Installation - Step 7
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Setting Up SSL Certificates"
echo "=============================================="

# Domains to secure
DOMAINS="radio.peoplewelike.club,stream.peoplewelike.club,ingest.peoplewelike.club"

# Check if nginx is running
echo "[1/4] Checking nginx status..."
if ! systemctl is-active --quiet nginx; then
    echo "    Starting nginx..."
    systemctl start nginx
fi

# Test nginx config first
echo "[2/4] Testing nginx configuration..."
if ! nginx -t 2>&1; then
    echo "ERROR: nginx configuration test failed"
    echo "Fix nginx configuration before obtaining SSL certificates"
    exit 1
fi

# Reload nginx to apply any pending changes
systemctl reload nginx

# Obtain SSL certificates
echo "[3/4] Obtaining SSL certificates with Certbot..."
echo ""
echo "Requesting certificates for:"
echo "  - radio.peoplewelike.club"
echo "  - stream.peoplewelike.club"
echo "  - ingest.peoplewelike.club"
echo ""

# Use EMAIL from environment or default
CERTBOT_EMAIL="${CERTBOT_EMAIL:-${EMAIL:-admin@peoplewelike.club}}"

# Run certbot
certbot --nginx \
    -d radio.peoplewelike.club \
    -d stream.peoplewelike.club \
    -d ingest.peoplewelike.club \
    --non-interactive \
    --agree-tos \
    --email "$CERTBOT_EMAIL" \
    --redirect \
    --keep-until-expiring

# Verify certificates
echo ""
echo "[4/4] Verifying SSL certificates..."
for domain in radio.peoplewelike.club stream.peoplewelike.club ingest.peoplewelike.club; do
    if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]] || \
       [[ -f "/etc/letsencrypt/live/radio.peoplewelike.club/fullchain.pem" ]]; then
        echo "    ✓ Certificate for $domain: OK"
    else
        echo "    ✗ Certificate for $domain: NOT FOUND"
    fi
done

# Set up auto-renewal
echo ""
echo "Setting up automatic certificate renewal..."
systemctl enable certbot.timer
systemctl start certbot.timer

# Test renewal
echo "Testing renewal process..."
certbot renew --dry-run || true

echo ""
echo "=============================================="
echo "  SSL Certificates Configured"
echo "=============================================="
echo ""
echo "Certificates location: /etc/letsencrypt/live/"
echo "Auto-renewal: enabled (certbot.timer)"
echo ""
echo "HTTPS URLs:"
echo "  https://radio.peoplewelike.club/"
echo "  https://stream.peoplewelike.club/"
echo "  https://ingest.peoplewelike.club/"
echo ""
echo "HLS Stream URL:"
echo "  https://radio.peoplewelike.club/hls/current/index.m3u8"
echo ""
echo "Next step: Run ./08-create-player.sh"
