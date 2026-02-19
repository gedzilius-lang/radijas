#!/usr/bin/env python3
"""
Radio switch daemon — detects live vs autodj by polling RTMP stats.
Writes active source to /run/radio/active.
Combined with relay into one container (started by entrypoint.sh).
"""

import os
import time
import re
import urllib.request

STAT_URL = os.environ.get("RTMP_STAT_URL", "http://rtmp:8089/rtmp_stat")
ACTIVE_FILE = "/run/radio/active"


def nclients_live() -> int:
    """Parse RTMP stat XML to count clients on the 'club' application."""
    try:
        with urllib.request.urlopen(STAT_URL, timeout=3) as resp:
            xml = resp.read().decode("utf-8", errors="ignore")
    except Exception:
        return 0

    # Simple XML parsing — look for <application> blocks with name "club"
    # and extract nclients from the first stream inside
    in_app = False
    found_club = False
    for line in xml.splitlines():
        line = line.strip()
        if "<application>" in line:
            in_app = True
            found_club = False
        if in_app and "<name>club</name>" in line:
            found_club = True
        if in_app and found_club:
            m = re.search(r"<nclients>(\d+)</nclients>", line)
            if m:
                return int(m.group(1))
        if "</application>" in line:
            in_app = False
            found_club = False
    return 0


def main():
    os.makedirs(os.path.dirname(ACTIVE_FILE), exist_ok=True)
    prev = None

    while True:
        nc = nclients_live()
        # nclients includes the publisher itself; >0 means someone is streaming
        mode = "live" if nc > 0 else "autodj"

        if mode != prev:
            tmp = ACTIVE_FILE + ".tmp"
            with open(tmp, "w") as f:
                f.write(mode + "\n")
            os.replace(tmp, ACTIVE_FILE)
            prev = mode
            print(f"[switchd] active={mode} (nclients_club={nc})", flush=True)

        time.sleep(1)


if __name__ == "__main__":
    main()
