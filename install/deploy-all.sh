#!/usr/bin/env bash
###############################################################################
# MASTER DEPLOYMENT SCRIPT
# People We Like Radio - Run All Installation Steps
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                                                                  ║"
echo "║           PEOPLE WE LIKE RADIO - FULL DEPLOYMENT                 ║"
echo "║                                                                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

# Confirm
echo "This will install and configure:"
echo "  - nginx with RTMP module"
echo "  - Liquidsoap AutoDJ"
echo "  - FFmpeg video overlay"
echo "  - HLS relay for seamless switching"
echo "  - SSL certificates (Let's Encrypt)"
echo "  - Video.js web player"
echo ""
echo "VPS: 72.60.181.89"
echo "Domains: radio.peoplewelike.club, stream.peoplewelike.club, ingest.peoplewelike.club"
echo ""
read -p "Continue with installation? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi

# Make all scripts executable
chmod +x "$SCRIPT_DIR"/*.sh

# Track time
START_TIME=$(date +%s)

# Run each step
STEPS=(
    "00-preflight.sh:Preflight Check"
    "01-install-dependencies.sh:Install Dependencies"
    "02-create-directories.sh:Create Directories"
    "03-configure-nginx.sh:Configure Nginx"
    "04-configure-liquidsoap.sh:Configure Liquidsoap"
    "05-create-scripts.sh:Create Scripts"
    "06-create-services.sh:Create Services"
    "07-setup-ssl.sh:Setup SSL"
    "08-create-player.sh:Create Player"
    "09-finalize.sh:Finalize"
)

TOTAL_STEPS=${#STEPS[@]}
CURRENT=0

for step in "${STEPS[@]}"; do
    CURRENT=$((CURRENT + 1))
    SCRIPT=$(echo "$step" | cut -d: -f1)
    DESC=$(echo "$step" | cut -d: -f2)

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Step $CURRENT/$TOTAL_STEPS: $DESC"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    if [[ -f "$SCRIPT_DIR/$SCRIPT" ]]; then
        if ! bash "$SCRIPT_DIR/$SCRIPT"; then
            echo ""
            echo "ERROR: Step failed: $SCRIPT"
            echo "Fix the issue and run this script again, or run individual steps manually."
            exit 1
        fi
    else
        echo "WARNING: Script not found: $SCRIPT"
    fi
done

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                                                                  ║"
echo "║              🎉 DEPLOYMENT COMPLETE! 🎉                          ║"
echo "║                                                                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Installation completed in ${MINUTES}m ${SECONDS}s"
echo ""
echo "Next steps:"
echo "  1. Upload video loop(s) to: /var/lib/radio/loops/"
echo "  2. Upload music files to:   /var/lib/radio/music/[day]/[phase]/"
echo "  3. Restart services:        radio-ctl restart"
echo "  4. Test the player:         https://radio.peoplewelike.club/"
echo ""
echo "Credentials saved to: /root/radio-info.txt"
echo ""
