#!/usr/bin/env python3
"""
Radio HLS relay — generates a stable /hls/current/ playlist with monotonic
segment IDs and #EXT-X-DISCONTINUITY markers on source switch.

v2 FIX: caps segment window and deletes old segments to prevent inode exhaustion
(v1 bug: never cleaned up, accumulated 6.3M symlinks).

v2.1 FIX: find_m3u8() — nginx-rtmp names the live playlist after the stream key
(e.g. people.m3u8), not index.m3u8. Relay now finds any *.m3u8 in the source
directory as a fallback so live switching works regardless of stream key.
"""

import os
import time
import json
import shutil
import glob

ACTIVE_FILE = "/run/radio/active"
HLS_AUTODJ = os.environ.get("HLS_AUTODJ", "/var/www/hls/autodj")
HLS_LIVE = os.environ.get("HLS_LIVE", "/var/www/hls/live")
OUT_DIR = os.environ.get("HLS_CURRENT", "/var/www/hls/current")
STATUS_FILE = os.environ.get("STATUS_FILE", "/var/www/radio/data/status.json")
STATE_FILE = "/var/lib/radio-hls-relay/state.json"

# Keep this many segments in the output directory; delete older ones
MAX_SEGMENTS = 30
# Playlist window (how many segments in the m3u8)
PLAYLIST_WINDOW = 12


def read_active() -> str:
    try:
        v = open(ACTIVE_FILE, "r").read().strip()
        return v if v in ("autodj", "live") else "autodj"
    except Exception:
        return "autodj"


def find_m3u8(src_dir: str) -> str:
    """Return the playlist path for src_dir.
    Prefers index.m3u8; falls back to any *.m3u8 (nginx-rtmp names the
    live playlist after the stream key, e.g. people.m3u8, not index.m3u8).
    """
    fixed = os.path.join(src_dir, "index.m3u8")
    if os.path.exists(fixed):
        return fixed
    candidates = sorted(
        glob.glob(os.path.join(src_dir, "*.m3u8")),
        key=os.path.getmtime,
        reverse=True,
    )
    return candidates[0] if candidates else fixed


def load_state() -> dict:
    st = {"seq": 1, "last_mode": None}
    try:
        st.update(json.load(open(STATE_FILE, "r")))
    except Exception:
        pass
    if st.get("seq", 1) < 1:
        st["seq"] = 1
    return st


def save_state(st: dict):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE_FILE)


def parse_m3u8(path: str):
    """Returns (target_duration, [(dur_str, segment_filename), ...])"""
    target = 6
    pairs = []
    dur = None
    try:
        with open(path, "r", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("#EXT-X-TARGETDURATION:"):
                    try:
                        target = int(line.split(":")[1])
                    except Exception:
                        pass
                elif line.startswith("#EXTINF:"):
                    dur = line.split(":", 1)[1].split(",", 1)[0].strip()
                elif line and not line.startswith("#"):
                    seg = os.path.basename(line.split("?", 1)[0])
                    if dur is not None:
                        pairs.append((dur, seg))
                        dur = None
    except FileNotFoundError:
        pass
    return target, pairs


def atomic_write(path: str, data: str):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def cleanup_old_segments(out_dir: str, current_seq: int):
    """Remove segments older than MAX_SEGMENTS to prevent inode exhaustion."""
    cutoff = current_seq - MAX_SEGMENTS
    if cutoff <= 0:
        return
    for entry in os.listdir(out_dir):
        if not entry.startswith("seg-") or not entry.endswith(".ts"):
            continue
        try:
            seg_num = int(entry[4:-3])  # seg-NNN.ts
            if seg_num < cutoff:
                os.remove(os.path.join(out_dir, entry))
        except (ValueError, OSError):
            pass


def write_status(mode: str, seq: int):
    """Write /api/status JSON."""
    try:
        os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
        data = {
            "source": mode,
            "seq": seq,
            "updated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }
        atomic_write(STATUS_FILE, json.dumps(data))
    except Exception:
        pass


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    st = load_state()

    while True:
        mode = read_active()
        src_dir = HLS_LIVE if mode == "live" else HLS_AUTODJ
        m3u8 = find_m3u8(src_dir)
        target, pairs = parse_m3u8(m3u8)

        if not pairs:
            time.sleep(0.5)
            continue

        pairs = pairs[-PLAYLIST_WINDOW:]
        disc = (st.get("last_mode") is not None and st.get("last_mode") != mode)

        out_lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            f"#EXT-X-TARGETDURATION:{target}",
            f"#EXT-X-MEDIA-SEQUENCE:{max(st['seq'] - len(pairs), 0)}",
        ]
        if disc:
            out_lines.append("#EXT-X-DISCONTINUITY")

        seq = st["seq"]
        for dur, seg in pairs:
            src_path = os.path.join(src_dir, seg)
            if not os.path.exists(src_path):
                continue
            out_name = f"seg-{seq}.ts"
            out_path = os.path.join(OUT_DIR, out_name)

            try:
                if os.path.islink(out_path) or os.path.exists(out_path):
                    os.remove(out_path)
                os.symlink(src_path, out_path)
            except Exception:
                try:
                    shutil.copy2(src_path, out_path)
                except Exception:
                    pass

            out_lines.append(f"#EXTINF:{dur},")
            out_lines.append(out_name)
            seq += 1

        atomic_write(os.path.join(OUT_DIR, "index.m3u8"), "\n".join(out_lines) + "\n")

        st["seq"] = seq
        st["last_mode"] = mode
        save_state(st)

        # v2: clean up old segments
        cleanup_old_segments(OUT_DIR, seq)

        # Write status for /api/status
        write_status(mode, seq)

        time.sleep(0.5)


if __name__ == "__main__":
    main()
