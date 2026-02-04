#!/usr/bin/env bash
###############################################################################
# CONFIGURE LIQUIDSOAP
# People We Like Radio Installation - Step 4
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
# Liquidsoap 2.x compatible

# ============================================
# SETTINGS
# ============================================

settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

# ============================================
# MUSIC LIBRARY PATHS
# ============================================

music_root = "/var/lib/radio/music"

# Schedule folders (weekday/phase)
monday_morning    = "#{music_root}/monday/morning"
monday_day        = "#{music_root}/monday/day"
monday_night      = "#{music_root}/monday/night"

tuesday_morning   = "#{music_root}/tuesday/morning"
tuesday_day       = "#{music_root}/tuesday/day"
tuesday_night     = "#{music_root}/tuesday/night"

wednesday_morning = "#{music_root}/wednesday/morning"
wednesday_day     = "#{music_root}/wednesday/day"
wednesday_night   = "#{music_root}/wednesday/night"

thursday_morning  = "#{music_root}/thursday/morning"
thursday_day      = "#{music_root}/thursday/day"
thursday_night    = "#{music_root}/thursday/night"

friday_morning    = "#{music_root}/friday/morning"
friday_day        = "#{music_root}/friday/day"
friday_night      = "#{music_root}/friday/night"

saturday_morning  = "#{music_root}/saturday/morning"
saturday_day      = "#{music_root}/saturday/day"
saturday_night    = "#{music_root}/saturday/night"

sunday_morning    = "#{music_root}/sunday/morning"
sunday_day        = "#{music_root}/sunday/day"
sunday_night      = "#{music_root}/sunday/night"

default_folder    = "#{music_root}/default"

# ============================================
# PLAYLIST SOURCES (with fallback)
# ============================================

# Create playlist sources for each timeslot
# mode="randomize" shuffles the playlist
# reload_mode="watch" reloads when files change

def make_playlist(folder)
  playlist(
    mode="randomize",
    reload_mode="watch",
    folder
  )
end

# Monday
pl_mon_morning = make_playlist(monday_morning)
pl_mon_day     = make_playlist(monday_day)
pl_mon_night   = make_playlist(monday_night)

# Tuesday
pl_tue_morning = make_playlist(tuesday_morning)
pl_tue_day     = make_playlist(tuesday_day)
pl_tue_night   = make_playlist(tuesday_night)

# Wednesday
pl_wed_morning = make_playlist(wednesday_morning)
pl_wed_day     = make_playlist(wednesday_day)
pl_wed_night   = make_playlist(wednesday_night)

# Thursday
pl_thu_morning = make_playlist(thursday_morning)
pl_thu_day     = make_playlist(thursday_day)
pl_thu_night   = make_playlist(thursday_night)

# Friday
pl_fri_morning = make_playlist(friday_morning)
pl_fri_day     = make_playlist(friday_day)
pl_fri_night   = make_playlist(friday_night)

# Saturday
pl_sat_morning = make_playlist(saturday_morning)
pl_sat_day     = make_playlist(saturday_day)
pl_sat_night   = make_playlist(saturday_night)

# Sunday
pl_sun_morning = make_playlist(sunday_morning)
pl_sun_day     = make_playlist(sunday_day)
pl_sun_night   = make_playlist(sunday_night)

# Default fallback playlist
pl_default = make_playlist(default_folder)

# Emergency fallback (silence with metadata)
emergency = blank(id="emergency")

# ============================================
# SCHEDULE SWITCHING
# ============================================

# Time ranges:
# morning: 06:00 - 12:00  (6h-12h)
# day:     12:00 - 18:00  (12h-18h)
# night:   18:00 - 06:00  (18h-6h)

# Monday schedule
monday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 1w}, pl_mon_morning),
    ({12h-18h and 1w}, pl_mon_day),
    ({(18h-24h or 0h-6h) and 1w}, pl_mon_night)
  ]
)

# Tuesday schedule
tuesday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 2w}, pl_tue_morning),
    ({12h-18h and 2w}, pl_tue_day),
    ({(18h-24h or 0h-6h) and 2w}, pl_tue_night)
  ]
)

# Wednesday schedule
wednesday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 3w}, pl_wed_morning),
    ({12h-18h and 3w}, pl_wed_day),
    ({(18h-24h or 0h-6h) and 3w}, pl_wed_night)
  ]
)

# Thursday schedule
thursday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 4w}, pl_thu_morning),
    ({12h-18h and 4w}, pl_thu_day),
    ({(18h-24h or 0h-6h) and 4w}, pl_thu_night)
  ]
)

# Friday schedule
friday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 5w}, pl_fri_morning),
    ({12h-18h and 5w}, pl_fri_day),
    ({(18h-24h or 0h-6h) and 5w}, pl_fri_night)
  ]
)

# Saturday schedule
saturday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 6w}, pl_sat_morning),
    ({12h-18h and 6w}, pl_sat_day),
    ({(18h-24h or 0h-6h) and 6w}, pl_sat_night)
  ]
)

# Sunday schedule
sunday = switch(
  track_sensitive=false,
  [
    ({6h-12h and 7w}, pl_sun_morning),
    ({12h-18h and 7w}, pl_sun_day),
    ({(18h-24h or 0h-6h) and 7w}, pl_sun_night)
  ]
)

# Combine all days with fallbacks
scheduled = fallback(
  track_sensitive=false,
  [
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
    pl_default,
    emergency
  ]
)

# ============================================
# AUDIO PROCESSING
# ============================================

# Apply crossfade between tracks (3 second crossfade)
radio = crossfade(
  duration=3.0,
  fade_in=1.5,
  fade_out=1.5,
  scheduled
)

# Normalize audio levels
radio = normalize(radio)

# ============================================
# METADATA HANDLING
# ============================================

# JSON file for now-playing data
nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title = m["title"]
  artist = m["artist"]
  album = m["album"]
  filename = m["filename"]
  dur = m["duration"]
  dur_val = if dur == "" then "0" else dur end
  started = string(int_of_float(time()))

  # Create JSON output with duration and started_at for countdown
  json_data = '{"title":"#{title}","artist":"#{artist}","album":"#{album}","filename":"#{filename}","duration":#{dur_val},"started_at":#{started},"mode":"autodj","updated":"#{time.string(format="%Y-%m-%dT%H:%M:%SZ")}"}'

  # Write to file
  file.write(data=json_data, nowplaying_file)

  # Log
  print("Now playing: #{artist} - #{title} (#{dur_val}s)")

  # Return metadata unchanged
  m
end

# Apply metadata handler
radio = metadata.map(write_nowplaying, radio)

# ============================================
# OUTPUT TO RTMP
# ============================================

# Output audio to nginx-rtmp autodj_audio application
# Liquidsoap 2.x: use output.url with %ffmpeg (output.rtmp does not exist)
output.url(
  id="rtmp_out",
  fallible=true,
  %ffmpeg(format="flv",
    %audio(codec="aac", b="128k", ar=44100, channels=2)
  ),
  "rtmp://127.0.0.1:1935/autodj_audio/stream",
  radio
)
LIQEOF

echo "    Created /etc/liquidsoap/radio.liq"

# Create a simpler fallback config if the main one has issues
echo "[2/2] Creating fallback Liquidsoap configuration..."
cat > /etc/liquidsoap/radio-simple.liq <<'LIQSIMPLEEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - Simplified AutoDJ Configuration
# Use this if the main config has issues

settings.server.telnet := true
settings.server.telnet.port := 1234
settings.log.file.path := "/var/log/liquidsoap/radio.log"
settings.log.level := 3

# Music root
music_root = "/var/lib/radio/music"

# Scan all subdirectories for music
all_music = playlist(
  mode="randomize",
  reload_mode="watch",
  "#{music_root}"
)

# Fallback to silence
emergency = blank(id="emergency")

# Main source with fallback
radio = fallback(track_sensitive=false, [all_music, emergency])

# Crossfade
radio = crossfade(duration=3.0, radio)

# Normalize
radio = normalize(radio)

# Metadata JSON
nowplaying_file = "/var/www/radio/data/nowplaying.json"

def write_nowplaying(m)
  title = m["title"]
  artist = m["artist"]
  dur = m["duration"]
  dur_val = if dur == "" then "0" else dur end
  started = string(int_of_float(time()))
  json_data = '{"title":"#{title}","artist":"#{artist}","duration":#{dur_val},"started_at":#{started},"mode":"autodj","updated":"#{time.string(format="%Y-%m-%dT%H:%M:%SZ")}"}'
  file.write(data=json_data, nowplaying_file)
  print("Now playing: #{artist} - #{title} (#{dur_val}s)")
  m
end

radio = metadata.map(write_nowplaying, radio)

# Output to RTMP (Liquidsoap 2.x)
output.url(
  id="rtmp_out",
  fallible=true,
  %ffmpeg(format="flv",
    %audio(codec="aac", b="128k", ar=44100, channels=2)
  ),
  "rtmp://127.0.0.1:1935/autodj_audio/stream",
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
echo "Schedule (server time):"
echo "  morning: 06:00 - 12:00"
echo "  day:     12:00 - 18:00"
echo "  night:   18:00 - 06:00"
echo ""
echo "Features enabled:"
echo "  - Crossfade (3 seconds)"
echo "  - Audio normalization"
echo "  - Metadata JSON output"
echo "  - Auto-reload on file changes"
echo ""
echo "Next step: Run ./05-create-scripts.sh"
