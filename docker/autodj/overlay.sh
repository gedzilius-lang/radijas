#!/usr/bin/env bash
set -euo pipefail

# AutoDJ overlay: picks music via scheduler.py, combines with a random
# loop video, publishes A/V stream to nginx-rtmp autodj application.

RTMP_OUT="${RTMP_OUT:-rtmp://rtmp:1935/autodj/index}"
MUSIC_ROOT="${MUSIC_ROOT:-/music}"
LOOPS_DIR="${LOOPS_DIR:-/loops}"
NOWPLAYING_FILE="${NOWPLAYING_FILE:-/var/www/radio/data/nowplaying}"
FPS=25
FRAG=6
GOP=$((FPS * FRAG))  # 150 frames — matches HLS fragment duration

log() { echo "[$(date -Is)] $*"; }

write_nowplaying() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    # Strip extension, replace underscores/hyphens with spaces for display
    local title="${filename%.*}"
    local updated
    updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local tmp="${NOWPLAYING_FILE}.tmp"
    printf '{"mode":"autodj","artist":"People We Like","title":"%s","updated":"%s"}\n' \
        "$title" "$updated" > "$tmp"
    mv "$tmp" "$NOWPLAYING_FILE"
}

pick_loop() {
    local loops
    loops=$(find "$LOOPS_DIR" -maxdepth 1 -name '*.mp4' -type f 2>/dev/null)
    if [[ -z "$loops" ]]; then
        log "FATAL: No loop videos found in $LOOPS_DIR"
        exit 1
    fi
    echo "$loops" | shuf -n1
}

# Wait for RTMP server to be ready
log "Waiting for RTMP server..."
for i in $(seq 1 30); do
    if wget -qO- "http://rtmp:8089/rtmp_stat" >/dev/null 2>&1; then
        log "RTMP server ready after ~${i}s"
        break
    fi
    sleep 1
done

log "Starting AutoDJ loop"

while true; do
    # Pick a track using the Zurich-time scheduler
    TRACK=$(python3 /app/scheduler.py)
    if [[ -z "$TRACK" ]]; then
        log "No tracks available, sleeping 10s..."
        sleep 10
        continue
    fi

    LOOP=$(pick_loop)
    log "Playing: $(basename "$TRACK") | Video: $(basename "$LOOP")"
    write_nowplaying "$TRACK"

    # Get audio duration to know when to pick next track
    DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$TRACK" 2>/dev/null || echo "0")

    if [[ "$DURATION" == "0" || -z "$DURATION" ]]; then
        log "WARN: Could not get duration for $TRACK, skipping"
        sleep 1
        continue
    fi

    # Probe loop video dimensions to skip scaling if already 720p
    LOOP_RES=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height -of csv=p=0 "$LOOP" 2>/dev/null || echo "0,0")
    LOOP_W="${LOOP_RES%%,*}"
    LOOP_H="${LOOP_RES##*,}"

    VF="fps=${FPS}"
    if [[ "$LOOP_W" != "1280" || "$LOOP_H" != "720" ]]; then
        VF="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,${VF}"
    fi

    # Stream one track: loop video + single audio file → RTMP
    # -t limits to track duration so we move to next track
    ffmpeg -hide_banner -loglevel warning \
        -re -stream_loop -1 -i "$LOOP" \
        -i "$TRACK" \
        -t "$DURATION" \
        -map 0:v:0 -map 1:a:0 \
        -vf "$VF" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
        -force_key_frames "expr:gte(t,n_forced*${FRAG})" \
        -b:v 1500k -maxrate 1500k -bufsize 3000k \
        -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
        -c:a aac -b:a 128k -ar 44100 -ac 2 \
        -flvflags no_duration_filesize \
        -f flv "$RTMP_OUT" || true

    log "Track finished, picking next..."
    sleep 0.5
done
