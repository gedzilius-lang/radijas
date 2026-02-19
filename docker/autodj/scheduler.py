#!/usr/bin/env python3
"""
AutoDJ Scheduler — picks music files based on Zurich time.

Dayparts (Europe/Zurich):
  morning  07:00–12:00
  day      12:00–17:00
  evening  17:00–22:00
  night    22:00–07:00

Folder structure under /music:
  /music/{monday..sunday}/{morning,day,evening,night}/*.mp3
  /music/{monday..sunday}/*.mp3           (day-level fallback)
  /music/allmusic/*.mp3                   (global fallback)
  /music/default/*.mp3                    (legacy v1 fallback)

Outputs one file path per invocation (called by overlay.sh in a loop).
"""

import os
import sys
import random
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
except ImportError:
    from backports.zoneinfo import ZoneInfo

MUSIC_ROOT = os.environ.get("MUSIC_ROOT", "/music")
TZ = ZoneInfo("Europe/Zurich")

DAYPARTS = [
    (7,  12, "morning"),
    (12, 17, "day"),
    (17, 22, "evening"),
    (22, 31, "night"),  # 31 = wraps past midnight, handled below
]

EXTENSIONS = {".mp3", ".flac", ".wav", ".ogg", ".m4a", ".aac"}


def get_daypart(hour: int) -> str:
    if 7 <= hour < 12:
        return "morning"
    elif 12 <= hour < 17:
        return "day"
    elif 17 <= hour < 22:
        return "evening"
    else:
        return "night"


def list_music(directory: str) -> list:
    if not os.path.isdir(directory):
        return []
    return [
        os.path.join(directory, f)
        for f in os.listdir(directory)
        if os.path.splitext(f)[1].lower() in EXTENSIONS
    ]


def pick_track() -> str:
    now = datetime.now(TZ)
    weekday = now.strftime("%A").lower()  # monday, tuesday, ...
    daypart = get_daypart(now.hour)

    # Try in order of specificity
    candidates = []

    # 1. Exact: /music/monday/morning/
    candidates = list_music(os.path.join(MUSIC_ROOT, weekday, daypart))
    if candidates:
        return random.choice(candidates)

    # 2. Day-level: /music/monday/
    candidates = list_music(os.path.join(MUSIC_ROOT, weekday))
    if candidates:
        return random.choice(candidates)

    # 3. Global fallback: /music/allmusic/
    candidates = list_music(os.path.join(MUSIC_ROOT, "allmusic"))
    if candidates:
        return random.choice(candidates)

    # 4. Legacy fallback: /music/default/
    candidates = list_music(os.path.join(MUSIC_ROOT, "default"))
    if candidates:
        return random.choice(candidates)

    # 5. Anything in any subfolder
    for root, dirs, files in os.walk(MUSIC_ROOT):
        for f in files:
            if os.path.splitext(f)[1].lower() in EXTENSIONS:
                candidates.append(os.path.join(root, f))
    if candidates:
        return random.choice(candidates)

    return ""


if __name__ == "__main__":
    track = pick_track()
    if not track:
        print("ERROR: No music files found in " + MUSIC_ROOT, file=sys.stderr)
        sys.exit(1)
    print(track)
