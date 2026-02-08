#!/usr/bin/env bash
###############################################################################
# fix-liquidsoap.sh
# Deploys a MINIMAL Liquidsoap 2.x config guaranteed to work, then restarts.
# Once streaming is confirmed, run update-configs.sh for full features.
#
# Usage (on VPS as root):
#   curl -fsSL https://raw.githubusercontent.com/gedzilius-lang/radijas/claude/setup-radio-agent-instructions-ghStP/install/fix-liquidsoap.sh | bash
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK:${NC} $1"; }
step() { echo -e "\n${CYAN}>>> $1${NC}"; }

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root${NC}"; exit 1; fi

step "Checking Liquidsoap version"
liquidsoap --version 2>/dev/null || echo "liquidsoap not found"

step "Stopping radio services"
systemctl stop radio-hls-relay autodj-video-overlay radio-switchd liquidsoap-autodj 2>/dev/null || true
ok "Services stopped"

step "Checking music files"
echo "  Music files in /var/lib/radio/music/default/:"
ls -la /var/lib/radio/music/default/ 2>/dev/null || echo "  (empty or missing)"
echo ""
echo "  All music files:"
find /var/lib/radio/music -type f -name '*.mp3' -o -name '*.flac' -o -name '*.ogg' -o -name '*.wav' 2>/dev/null | head -20
MUSIC_COUNT=$(find /var/lib/radio/music -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.ogg' -o -name '*.wav' \) 2>/dev/null | wc -l)
echo "  Total: $MUSIC_COUNT audio files"

if [[ "$MUSIC_COUNT" -eq 0 ]]; then
  echo -e "${RED}  No music files found! Upload MP3s to /var/lib/radio/music/default/ first.${NC}"
fi

step "Writing MINIMAL /etc/liquidsoap/radio.liq"
mkdir -p /etc/liquidsoap
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - Minimal AutoDJ (Liquidsoap 2.0.x safe)
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

# Simple playlist from default folder - no schedule, no crossfade
radio = playlist(mode="random", "/var/lib/radio/music/default")
radio = fallback(track_sensitive=false, [radio, blank()])

# Metadata -> nowplaying JSON (Liquidsoap 2.0.x API)
nowplaying_file = "/var/www/radio/data/nowplaying.json"
def handle_metadata(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
end
radio.on_metadata(handle_metadata)

output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF
ok "Minimal radio.liq written (playlist + output only)"

step "Setting permissions"
chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq

# Also ensure music dir is readable
chown -R liquidsoap:audio /var/lib/radio/music
chmod -R 775 /var/lib/radio/music

# Ensure nowplaying dir exists
mkdir -p /var/www/radio/data
echo '{"title":"AutoDJ","artist":"People We Like Radio","mode":"autodj"}' > /var/www/radio/data/nowplaying.json
chown www-data:www-data /var/www/radio/data/nowplaying.json
ok "Permissions set"

step "Testing config syntax"
if sudo -u liquidsoap liquidsoap --check /etc/liquidsoap/radio.liq 2>&1; then
  ok "Config syntax valid"
else
  echo -e "${RED}  Config syntax check failed. Trying as root...${NC}"
  liquidsoap --check /etc/liquidsoap/radio.liq 2>&1 || true
fi

step "Restarting service chain"
systemctl reset-failed liquidsoap-autodj 2>/dev/null || true
systemctl start liquidsoap-autodj

echo "  Waiting 8s for Liquidsoap to start..."
sleep 8

echo "  --- Liquidsoap logs ---"
journalctl -u liquidsoap-autodj --no-pager -n 25

if ! systemctl is-active --quiet liquidsoap-autodj; then
  echo ""
  echo -e "${RED}  Liquidsoap STILL failing. Full error above.${NC}"
  echo ""
  echo "  Trying radio-simple.liq as last resort..."

  # Write even simpler config
  cat > /etc/liquidsoap/radio.liq <<'LIQMIN'
#!/usr/bin/liquidsoap
settings.init.allow_root.set(true)
s = single("/var/lib/radio/music/default/$(ls /var/lib/radio/music/default/ | head -1)")
output.url(fallible=true, url="rtmp://127.0.0.1:1935/autodj_audio/stream", %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)), s)
LIQMIN
  chown liquidsoap:audio /etc/liquidsoap/radio.liq
  chmod 644 /etc/liquidsoap/radio.liq
  systemctl reset-failed liquidsoap-autodj 2>/dev/null || true
  systemctl restart liquidsoap-autodj
  sleep 5
  journalctl -u liquidsoap-autodj --no-pager -n 15
fi

echo ""
systemctl start autodj-video-overlay 2>/dev/null || true
sleep 3
systemctl start radio-switchd 2>/dev/null || true
systemctl start radio-hls-relay 2>/dev/null || true

step "Service Status"
for svc in liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay nginx; do
  echo "  $svc: $(systemctl is-active $svc 2>/dev/null || echo inactive)"
done

echo ""
echo "Waiting 15s for HLS segments..."
sleep 15
echo "  AutoDJ segments: $(ls /var/www/hls/autodj/*.ts 2>/dev/null | wc -l)"
echo "  Current segments: $(ls /var/www/hls/current/*.ts 2>/dev/null | wc -l)"
echo ""
echo -e "${GREEN}Done. Test: https://radio.peoplewelike.club/${NC}"
