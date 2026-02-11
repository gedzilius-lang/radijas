#!/usr/bin/env bash
###############################################################################
# CONFIGURE LIQUIDSOAP
# People We Like Radio Installation - Step 4
#
# Liquidsoap 2.2.x compatible - outputs HLS directly
# 4 dayparts per day: morning (06–10), day (10–18), evening (18–22), night (22–06)
# Night slot crosses midnight: e.g. Monday/night = Mon 22:00 – Tue 06:00
# Content root: /srv/radio/content/<day>/<slot>/
# Fallback chain: active slot → global _fallback → silence
###############################################################################
set -euo pipefail

echo "=============================================="
echo "  Configuring Liquidsoap"
echo "=============================================="

# Create main Liquidsoap configuration
echo "[1/2] Creating Liquidsoap configuration..."
cat > /etc/liquidsoap/radio.liq <<'LIQEOF'
#!/usr/bin/liquidsoap
# People We Like Radio - Program (AutoDJ) Configuration
# Liquidsoap 2.2.x compatible
#
# This outputs HLS to /var/www/hls/autodj/
# Live streaming is handled separately by nginx-rtmp
#
# Schedule (server local time):
#   morning:  06:00 – 10:00
#   day:      10:00 – 18:00
#   evening:  18:00 – 22:00
#   night:    22:00 – 06:00 (crosses midnight)

settings.log.level.set(3)

# ============================================
# CONTENT ROOT
# ============================================

root = "/srv/radio/content"
nowplaying_file = "/var/www/radio.peoplewelike.club/data/nowplaying.json"

# ============================================
# PLAYLIST HELPER
# ============================================

def make_playlist(folder)
  playlist(
    mode="randomize",
    reload=60,
    folder
  )
end

# ============================================
# SLOT PLAYLISTS (7 days x 4 parts = 28 + fallback)
# ============================================

# Monday
pl_mon_morning = make_playlist("#{root}/monday/morning")
pl_mon_day     = make_playlist("#{root}/monday/day")
pl_mon_evening = make_playlist("#{root}/monday/evening")
pl_mon_night   = make_playlist("#{root}/monday/night")

# Tuesday
pl_tue_morning = make_playlist("#{root}/tuesday/morning")
pl_tue_day     = make_playlist("#{root}/tuesday/day")
pl_tue_evening = make_playlist("#{root}/tuesday/evening")
pl_tue_night   = make_playlist("#{root}/tuesday/night")

# Wednesday
pl_wed_morning = make_playlist("#{root}/wednesday/morning")
pl_wed_day     = make_playlist("#{root}/wednesday/day")
pl_wed_evening = make_playlist("#{root}/wednesday/evening")
pl_wed_night   = make_playlist("#{root}/wednesday/night")

# Thursday
pl_thu_morning = make_playlist("#{root}/thursday/morning")
pl_thu_day     = make_playlist("#{root}/thursday/day")
pl_thu_evening = make_playlist("#{root}/thursday/evening")
pl_thu_night   = make_playlist("#{root}/thursday/night")

# Friday
pl_fri_morning = make_playlist("#{root}/friday/morning")
pl_fri_day     = make_playlist("#{root}/friday/day")
pl_fri_evening = make_playlist("#{root}/friday/evening")
pl_fri_night   = make_playlist("#{root}/friday/night")

# Saturday
pl_sat_morning = make_playlist("#{root}/saturday/morning")
pl_sat_day     = make_playlist("#{root}/saturday/day")
pl_sat_evening = make_playlist("#{root}/saturday/evening")
pl_sat_night   = make_playlist("#{root}/saturday/night")

# Sunday
pl_sun_morning = make_playlist("#{root}/sunday/morning")
pl_sun_day     = make_playlist("#{root}/sunday/day")
pl_sun_evening = make_playlist("#{root}/sunday/evening")
pl_sun_night   = make_playlist("#{root}/sunday/night")

# Global fallback
pl_fallback = make_playlist("#{root}/_fallback")

# Emergency silence
emergency = blank(id="emergency")

# ============================================
# SCHEDULE SWITCHING
# ============================================

monday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 1w},                        pl_mon_morning),
    ({10h-18h and 1w},                       pl_mon_day),
    ({18h-22h and 1w},                       pl_mon_evening),
    ({(22h-24h and 1w) or (0h-6h and 2w)},  pl_mon_night)
  ]
)

tuesday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 2w},                        pl_tue_morning),
    ({10h-18h and 2w},                       pl_tue_day),
    ({18h-22h and 2w},                       pl_tue_evening),
    ({(22h-24h and 2w) or (0h-6h and 3w)},  pl_tue_night)
  ]
)

wednesday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 3w},                        pl_wed_morning),
    ({10h-18h and 3w},                       pl_wed_day),
    ({18h-22h and 3w},                       pl_wed_evening),
    ({(22h-24h and 3w) or (0h-6h and 4w)},  pl_wed_night)
  ]
)

thursday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 4w},                        pl_thu_morning),
    ({10h-18h and 4w},                       pl_thu_day),
    ({18h-22h and 4w},                       pl_thu_evening),
    ({(22h-24h and 4w) or (0h-6h and 5w)},  pl_thu_night)
  ]
)

friday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 5w},                        pl_fri_morning),
    ({10h-18h and 5w},                       pl_fri_day),
    ({18h-22h and 5w},                       pl_fri_evening),
    ({(22h-24h and 5w) or (0h-6h and 6w)},  pl_fri_night)
  ]
)

saturday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 6w},                        pl_sat_morning),
    ({10h-18h and 6w},                       pl_sat_day),
    ({18h-22h and 6w},                       pl_sat_evening),
    ({(22h-24h and 6w) or (0h-6h and 7w)},  pl_sat_night)
  ]
)

sunday = switch(
  track_sensitive=false,
  [
    ({6h-10h and 7w},                        pl_sun_morning),
    ({10h-18h and 7w},                       pl_sun_day),
    ({18h-22h and 7w},                       pl_sun_evening),
    ({(22h-24h and 7w) or (0h-6h and 1w)},  pl_sun_night)
  ]
)

# Combine: active day → fallback → silence
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
    pl_fallback,
    emergency
  ]
)

# ============================================
# AUDIO PROCESSING
# ============================================

# Audio processing with crossfade
radio = crossfade(
  duration=3.0,
  fade_in=1.5,
  fade_out=1.5,
  scheduled
)

radio = normalize(radio)

# Make source infallible (adds silence if no content available)
radio = mksafe(radio)

# ============================================
# METADATA HANDLING
# ============================================

def write_nowplaying(m)
  title = m["title"]
  artist = m["artist"]
  album = m["album"]
  filename = m["filename"]
  dur = m["duration"]
  dur_val = if dur == "" then "0" else dur end
  started = "#{int_of_float(time())}"

  json_data = '{"title":"#{title}","artist":"#{artist}","album":"#{album}","filename":"#{filename}","duration":#{dur_val},"started_at":#{started},"mode":"program"}'

  ignore(file.write(data=json_data, nowplaying_file))
  print("Now playing: #{artist} - #{title}")
  ()
end

radio.on_track(write_nowplaying)

# ============================================
# HLS OUTPUT
# ============================================

output.file.hls(
  id="hls_autodj",
  playlist="index.m3u8",
  segment_duration=6.0,
  segments=20,
  segments_overhead=5,
  "/var/www/hls/autodj",
  [
    ("aac128",
      %ffmpeg(
        format="mpegts",
        %audio(codec="aac", b="128k", ar=44100, channels=2)
      )
    )
  ],
  radio
)
LIQEOF

echo "    Created /etc/liquidsoap/radio.liq"

# Set permissions
chown -R liquidsoap:audio /etc/liquidsoap
chmod 644 /etc/liquidsoap/*.liq

# Create data directory and initial nowplaying.json
mkdir -p /var/www/radio.peoplewelike.club/data
cat > /var/www/radio.peoplewelike.club/data/nowplaying.json <<'NPEOF'
{"title":"Starting...","artist":"","mode":"program","updated":""}
NPEOF
chown www-data:www-data /var/www/radio.peoplewelike.club/data/nowplaying.json
chmod 644 /var/www/radio.peoplewelike.club/data/nowplaying.json

echo ""
echo "=============================================="
echo "  Liquidsoap Configuration Complete"
echo "=============================================="
echo ""
echo "Configuration file: /etc/liquidsoap/radio.liq"
echo ""
echo "Schedule (server local time):"
echo "  morning:  06:00 – 10:00"
echo "  day:      10:00 – 18:00"
echo "  evening:  18:00 – 22:00"
echo "  night:    22:00 – 06:00 (crosses midnight)"
echo ""
echo "Content root: /srv/radio/content/<day>/<slot>/"
echo "Fallback:     /srv/radio/content/_fallback/"
echo ""
echo "HLS output:   /var/www/hls/autodj/"
echo ""
echo "Playlists rescan every 60 seconds (no restart needed for new uploads)."
echo ""
echo "Next step: Run ./05-create-scripts.sh"
