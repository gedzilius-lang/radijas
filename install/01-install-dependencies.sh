#!/usr/bin/env bash
###############################################################################
# INSTALL DEPENDENCIES
# People We Like Radio Installation - Step 1
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Installing Dependencies"
echo "=============================================="

export DEBIAN_FRONTEND=noninteractive

# Update package lists
echo "[1/8] Updating package lists..."
apt-get update -qq

# Install build essentials and tools
echo "[2/8] Installing build tools..."
apt-get install -y -qq \
    build-essential \
    git \
    curl \
    wget \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

# Install FFmpeg
echo "[3/8] Installing FFmpeg..."
apt-get install -y -qq ffmpeg

# Verify FFmpeg
ffmpeg -version | head -1

# Install nginx with RTMP module
echo "[4/8] Installing nginx with RTMP module..."
apt-get install -y -qq libnginx-mod-rtmp nginx

# Verify nginx-rtmp module
if nginx -V 2>&1 | grep -q rtmp; then
    echo "    nginx-rtmp module: OK"
else
    echo "    WARNING: RTMP module may not be loaded"
fi

# Install Liquidsoap from official repository
echo "[5/8] Installing Liquidsoap..."
# Add liquidsoap repository
apt-get install -y -qq liquidsoap

# Verify Liquidsoap
liquidsoap --version | head -1

# Install Python3 and dependencies
echo "[6/8] Installing Python3..."
apt-get install -y -qq python3 python3-pip python3-venv

# Install certbot for SSL
echo "[7/8] Installing Certbot..."
apt-get install -y -qq certbot python3-certbot-nginx

# Install additional utilities
echo "[8/8] Installing utilities..."
apt-get install -y -qq \
    jq \
    xmlstarlet \
    htop \
    iotop \
    ncdu

# Create radio system user
echo ""
echo "Creating radio system user..."
if ! id "radio" &>/dev/null; then
    useradd -r -s /bin/false -d /var/lib/radio radio
    echo "    Created user: radio"
else
    echo "    User 'radio' already exists"
fi

# Create liquidsoap user if not exists
if ! id "liquidsoap" &>/dev/null; then
    useradd -r -s /bin/false -d /var/lib/liquidsoap -g audio liquidsoap
    echo "    Created user: liquidsoap"
else
    echo "    User 'liquidsoap' already exists"
fi

# Add users to audio group
usermod -aG audio radio 2>/dev/null || true
usermod -aG audio liquidsoap 2>/dev/null || true
usermod -aG audio www-data 2>/dev/null || true

echo ""
echo "=============================================="
echo "  Dependencies Installed Successfully"
echo "=============================================="
echo ""
echo "Installed versions:"
echo "  - nginx: $(nginx -v 2>&1 | cut -d/ -f2)"
echo "  - ffmpeg: $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"
echo "  - liquidsoap: $(liquidsoap --version 2>&1 | head -1)"
echo "  - python3: $(python3 --version | awk '{print $2}')"
echo "  - certbot: $(certbot --version 2>&1 | awk '{print $2}')"
echo ""
echo "Next step: Run ./02-create-directories.sh"
