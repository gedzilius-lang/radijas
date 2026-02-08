#!/usr/bin/env bash
###############################################################################
# fix-liquidsoap.sh
# Replaces Liquidsoap config with 2.x-compatible version and restarts services
#
# Usage (on VPS as root):
#   curl -fsSL https://raw.githubusercontent.com/gedzilius-lang/radijas/claude/setup-radio-agent-instructions-ghStP/install/fix-liquidsoap.sh | bash
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK:${NC} $1"; }
step() { echo -e "\n${CYAN}>>> $1${NC}"; }

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Run as root${NC}"; exit 1; fi

step "Stopping radio services"
systemctl stop radio-hls-relay autodj-video-overlay radio-switchd liquidsoap-autodj 2>/dev/null || true
ok "Services stopped"

step "Writing /etc/liquidsoap/radio.liq (Liquidsoap 2.x)"
mkdir -p /etc/liquidsoap
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ (Liquidsoap 2.x)
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

music_root = "/var/lib/radio/music"

def make_playlist(folder)
  playlist(mode="random", reload_mode="watch", folder)
end

pl_mon_morning = make_playlist("#{music_root}/monday/morning")
pl_mon_day     = make_playlist("#{music_root}/monday/day")
pl_mon_night   = make_playlist("#{music_root}/monday/night")
pl_tue_morning = make_playlist("#{music_root}/tuesday/morning")
pl_tue_day     = make_playlist("#{music_root}/tuesday/day")
pl_tue_night   = make_playlist("#{music_root}/tuesday/night")
pl_wed_morning = make_playlist("#{music_root}/wednesday/morning")
pl_wed_day     = make_playlist("#{music_root}/wednesday/day")
pl_wed_night   = make_playlist("#{music_root}/wednesday/night")
pl_thu_morning = make_playlist("#{music_root}/thursday/morning")
pl_thu_day     = make_playlist("#{music_root}/thursday/day")
pl_thu_night   = make_playlist("#{music_root}/thursday/night")
pl_fri_morning = make_playlist("#{music_root}/friday/morning")
pl_fri_day     = make_playlist("#{music_root}/friday/day")
pl_fri_night   = make_playlist("#{music_root}/friday/night")
pl_sat_morning = make_playlist("#{music_root}/saturday/morning")
pl_sat_day     = make_playlist("#{music_root}/saturday/day")
pl_sat_night   = make_playlist("#{music_root}/saturday/night")
pl_sun_morning = make_playlist("#{music_root}/sunday/morning")
pl_sun_day     = make_playlist("#{music_root}/sunday/day")
pl_sun_night   = make_playlist("#{music_root}/sunday/night")

pl_default = make_playlist("#{music_root}/default")
emergency  = blank(id="emergency")

monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])
radio = crossfade(duration=2.0, scheduled)

nowplaying_file = "/var/www/radio/data/nowplaying.json"
def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end
radio = metadata.map(write_nowplaying, radio)

output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF
ok "radio.liq written"

step "Writing /etc/liquidsoap/radio-simple.liq (fallback)"
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLE'
#!/usr/bin/liquidsoap
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

all_music = playlist(mode="random", reload_mode="watch", "/var/lib/radio/music")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=2.0, radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"
def write_nowplaying(m)
  title = m["title"]; artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end
radio = metadata.map(write_nowplaying, radio)

output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQSIMPLE
ok "radio-simple.liq written"

step "Setting permissions"
chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq
ok "Permissions set"

step "Restarting service chain"
systemctl reset-failed liquidsoap-autodj 2>/dev/null || true
systemctl start liquidsoap-autodj
sleep 5

# Check if liquidsoap is actually running
if ! systemctl is-active --quiet liquidsoap-autodj; then
  echo -e "${RED}  Liquidsoap failed to start. Logs:${NC}"
  journalctl -u liquidsoap-autodj --no-pager -n 15
  exit 1
fi
ok "liquidsoap-autodj running"

systemctl start autodj-video-overlay
sleep 3
systemctl start radio-switchd
systemctl start radio-hls-relay
ok "All services started"

step "Verification"
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
