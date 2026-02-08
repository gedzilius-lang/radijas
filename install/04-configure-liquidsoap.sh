#!/usr/bin/env bash
###############################################################################
# CONFIGURE LIQUIDSOAP
# People We Like Radio Installation - Step 4
# Compatible with Liquidsoap 2.x (Ubuntu 22.04+)
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Configuring Liquidsoap"
echo "=============================================="

# Create main Liquidsoap configuration
echo "[1/2] Creating Liquidsoap configuration..."
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - AutoDJ Configuration
# Liquidsoap 2.x compatible (uses .set() and output.url)

settings.init.allow_root.set(true)
settings.log.stdout.set(true)

music_root = "/var/lib/radio/music"

def make_playlist(folder)
  playlist(mode="random", reload_mode="watch", folder)
end

# Monday
pl_mon_morning = make_playlist("#{music_root}/monday/morning")
pl_mon_day     = make_playlist("#{music_root}/monday/day")
pl_mon_night   = make_playlist("#{music_root}/monday/night")

# Tuesday
pl_tue_morning = make_playlist("#{music_root}/tuesday/morning")
pl_tue_day     = make_playlist("#{music_root}/tuesday/day")
pl_tue_night   = make_playlist("#{music_root}/tuesday/night")

# Wednesday
pl_wed_morning = make_playlist("#{music_root}/wednesday/morning")
pl_wed_day     = make_playlist("#{music_root}/wednesday/day")
pl_wed_night   = make_playlist("#{music_root}/wednesday/night")

# Thursday
pl_thu_morning = make_playlist("#{music_root}/thursday/morning")
pl_thu_day     = make_playlist("#{music_root}/thursday/day")
pl_thu_night   = make_playlist("#{music_root}/thursday/night")

# Friday
pl_fri_morning = make_playlist("#{music_root}/friday/morning")
pl_fri_day     = make_playlist("#{music_root}/friday/day")
pl_fri_night   = make_playlist("#{music_root}/friday/night")

# Saturday
pl_sat_morning = make_playlist("#{music_root}/saturday/morning")
pl_sat_day     = make_playlist("#{music_root}/saturday/day")
pl_sat_night   = make_playlist("#{music_root}/saturday/night")

# Sunday
pl_sun_morning = make_playlist("#{music_root}/sunday/morning")
pl_sun_day     = make_playlist("#{music_root}/sunday/day")
pl_sun_night   = make_playlist("#{music_root}/sunday/night")

pl_default = make_playlist("#{music_root}/default")
emergency  = blank(id="emergency")

# Schedule: morning 06-12, day 12-18, night 18-06
monday    = switch(track_sensitive=false, [({6h-12h and 1w}, pl_mon_morning), ({12h-18h and 1w}, pl_mon_day), ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)])
tuesday   = switch(track_sensitive=false, [({6h-12h and 2w}, pl_tue_morning), ({12h-18h and 2w}, pl_tue_day), ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)])
wednesday = switch(track_sensitive=false, [({6h-12h and 3w}, pl_wed_morning), ({12h-18h and 3w}, pl_wed_day), ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)])
thursday  = switch(track_sensitive=false, [({6h-12h and 4w}, pl_thu_morning), ({12h-18h and 4w}, pl_thu_day), ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)])
friday    = switch(track_sensitive=false, [({6h-12h and 5w}, pl_fri_morning), ({12h-18h and 5w}, pl_fri_day), ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)])
saturday  = switch(track_sensitive=false, [({6h-12h and 6w}, pl_sat_morning), ({12h-18h and 6w}, pl_sat_day), ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)])
sunday    = switch(track_sensitive=false, [({6h-12h and 7w}, pl_sun_morning), ({12h-18h and 7w}, pl_sun_day), ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)])

scheduled = fallback(track_sensitive=false, [monday, tuesday, wednesday, thursday, friday, saturday, sunday, pl_default, emergency])
radio = crossfade(duration=2.0, scheduled)

# Metadata -> JSON
nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title}")
  m
end

radio = metadata.map(write_nowplaying, radio)

# Output audio to nginx-rtmp (Liquidsoap 2.x syntax)
output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  radio
)
LIQEOF

echo "    Created /etc/liquidsoap/radio.liq"

# Create a simpler fallback config
echo "[2/2] Creating fallback Liquidsoap configuration..."
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLEEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - Simplified AutoDJ Configuration
# Liquidsoap 2.x compatible

settings.init.allow_root.set(true)
settings.log.stdout.set(true)

all_music = playlist(mode="random", reload_mode="watch", "/var/lib/radio/music")
emergency = blank(id="emergency")
radio = fallback(track_sensitive=false, [all_music, emergency])
radio = crossfade(duration=2.0, radio)

nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title  = m["title"]
  artist = m["artist"]
  json_data = '{"title":"#{title}","artist":"#{artist}","mode":"autodj","updated":"#{time.string("%Y-%m-%dT%H:%M:%SZ")}"}'
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
LIQSIMPLEEOF

echo "    Created /etc/liquidsoap/radio-simple.liq (fallback)"

# Set permissions
chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq

# Create initial nowplaying.json
mkdir -p /var/www/radio/data
cat > /var/www/radio/data/nowplaying.json <<'NPEOF'
{"title":"Starting...","artist":"AutoDJ","mode":"autodj","updated":""}
NPEOF
chown www-data:www-data /var/www/radio/data/nowplaying.json
chmod 644 /var/www/radio/data/nowplaying.json

echo ""
echo "=============================================="
echo "  Liquidsoap Configuration Complete"
echo "=============================================="
echo ""
echo "Configuration files:"
echo "  - /etc/liquidsoap/radio.liq (main - schedule-based)"
echo "  - /etc/liquidsoap/radio-simple.liq (fallback - all music)"
echo ""
echo "Next step: Run ./05-create-scripts.sh"
