#!/usr/bin/env python3
"""
People We Like Radio — API Server
Provides: listener presence counting, share snapshots, OG rendering.

Runs on port 3000; nginx proxies /api/listeners/*, /api/share/*, /share/*, /og/* here.

Listener counting uses an in-memory dict with TTL.
WARNING: not multi-instance safe. For multi-instance, switch to Redis.
"""

import json
import os
import sys
import time
import uuid
import html
import subprocess
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PORT = int(os.environ.get("RADIO_API_PORT", "3000"))
BASE_URL = os.environ.get("RADIO_BASE_URL", "https://radio.peoplewelike.club")
DATA_DIR = os.environ.get("RADIO_DATA_DIR", "/var/www/radio/data")
NOWPLAYING = os.path.join(DATA_DIR, "nowplaying.json")
SNAPSHOTS_DIR = os.path.join(DATA_DIR, "snapshots")
OG_DIR = os.path.join(DATA_DIR, "og")

LISTENER_TTL = 90  # seconds

# ---------------------------------------------------------------------------
# In-memory listener store
# ---------------------------------------------------------------------------
_listeners = {}        # session_id -> last_seen (float)
_listeners_lock = threading.Lock()


def _cleanup():
    cutoff = time.time() - LISTENER_TTL
    with _listeners_lock:
        expired = [k for k, v in _listeners.items() if v < cutoff]
        for k in expired:
            del _listeners[k]


def listener_heartbeat(session_id):
    with _listeners_lock:
        _listeners[session_id] = time.time()


def listener_count():
    _cleanup()
    with _listeners_lock:
        return len(_listeners)


# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
def create_snapshot():
    try:
        with open(NOWPLAYING) as f:
            np = json.load(f)
    except Exception:
        return None

    sid = uuid.uuid4().hex[:10]
    snap = {
        "id": sid,
        "title": np.get("title", "Unknown"),
        "artist": np.get("artist", "Unknown"),
        "album": np.get("album", ""),
        "mode": np.get("mode", "autodj"),
        "created_at": time.time(),
    }
    os.makedirs(SNAPSHOTS_DIR, exist_ok=True)
    with open(os.path.join(SNAPSHOTS_DIR, f"{sid}.json"), "w") as f:
        json.dump(snap, f)
    return {"snapshot_id": sid, "share_url": f"{BASE_URL}/share/{sid}"}


def load_snapshot(sid):
    # sanitise: allow only hex chars
    safe = "".join(c for c in sid if c in "0123456789abcdef")
    path = os.path.join(SNAPSHOTS_DIR, f"{safe}.json")
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# OG image generation (SVG -> PNG via rsvg-convert / ffmpeg fallback)
# ---------------------------------------------------------------------------
def _svg_escape(text):
    return html.escape(str(text)[:80])


def _generate_og_svg(snap):
    title = _svg_escape(snap.get("title", "Unknown"))
    artist = _svg_escape(snap.get("artist", "Unknown"))
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630">
  <rect width="1200" height="630" fill="#050505"/>
  <circle cx="200" cy="500" r="300" fill="#7c3aed" opacity=".05"/>
  <circle cx="1000" cy="100" r="200" fill="#7c3aed" opacity=".05"/>
  <text x="600" y="180" text-anchor="middle" font-family="Arial,Helvetica,sans-serif"
        font-size="28" fill="#404040" letter-spacing="8">PEOPLE WE LIKE RADIO</text>
  <rect x="100" y="220" width="1000" height="1" fill="#1a1a1a"/>
  <text x="600" y="340" text-anchor="middle" font-family="Arial,Helvetica,sans-serif"
        font-size="52" font-weight="bold" fill="#d4d4d4">{title}</text>
  <text x="600" y="410" text-anchor="middle" font-family="Arial,Helvetica,sans-serif"
        font-size="36" fill="#737373">{artist}</text>
  <rect x="100" y="470" width="1000" height="1" fill="#1a1a1a"/>
  <circle cx="545" cy="540" r="5" fill="#7c3aed"/>
  <text x="560" y="548" font-family="Arial,Helvetica,sans-serif"
        font-size="20" fill="#7c3aed" letter-spacing="4">NOW PLAYING</text>
</svg>"""


def get_og_image_path(sid):
    """Return path to PNG (generating if needed). None on failure."""
    os.makedirs(OG_DIR, exist_ok=True)
    png = os.path.join(OG_DIR, f"{sid}.png")
    if os.path.isfile(png):
        return png

    snap = load_snapshot(sid)
    if not snap:
        return None

    svg_content = _generate_og_svg(snap)
    svg_path = os.path.join(OG_DIR, f"{sid}.svg")
    with open(svg_path, "w") as f:
        f.write(svg_content)

    # Try converters in order of quality
    for cmd in [
        ["rsvg-convert", "-w", "1200", "-h", "630", svg_path, "-o", png],
        ["convert", svg_path, "-resize", "1200x630", png],
        ["ffmpeg", "-y", "-i", svg_path, "-vf", "scale=1200:630", png],
    ]:
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=15)
            if r.returncode == 0 and os.path.isfile(png):
                try:
                    os.unlink(svg_path)
                except OSError:
                    pass
                return png
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue

    # Fallback: keep SVG (some crawlers handle it)
    os.rename(svg_path, png)  # serve SVG with .png extension as last resort
    return png


# ---------------------------------------------------------------------------
# Share page HTML (server-rendered OG tags)
# ---------------------------------------------------------------------------
def share_page_html(snap, sid):
    title = html.escape(f"{snap['artist']} \u2014 {snap['title']}")
    og_img = f"{BASE_URL}/og/{sid}.png"
    share_url = f"{BASE_URL}/share/{sid}"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta property="og:title" content="{title}">
<meta property="og:description" content="Now playing on People We Like Radio">
<meta property="og:image" content="{og_img}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:url" content="{share_url}">
<meta property="og:type" content="music.song">
<meta property="og:site_name" content="People We Like Radio">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="Now playing on People We Like Radio">
<meta name="twitter:image" content="{og_img}">
<meta http-equiv="refresh" content="0;url={BASE_URL}">
<title>{title} — People We Like Radio</title>
</head>
<body style="background:#050505;color:#d4d4d4;font-family:sans-serif;text-align:center;padding:60px 20px">
<p style="color:#7c3aed;letter-spacing:4px;font-size:14px">PEOPLE WE LIKE RADIO</p>
<h1 style="margin:20px 0 8px">{html.escape(snap['title'])}</h1>
<p style="color:#737373;font-size:20px">{html.escape(snap['artist'])}</p>
<p style="margin-top:40px"><a href="{BASE_URL}" style="color:#7c3aed">Listen now &rarr;</a></p>
</body>
</html>"""


# ---------------------------------------------------------------------------
# HTTP Handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "RadioAPI/1.0"

    def log_message(self, fmt, *args):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S")
        sys.stderr.write(f"[{ts}] {fmt % args}\n")

    # -- helpers --
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, text, status=200):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except Exception:
            return {}

    def _not_found(self):
        self._json({"error": "not found"}, 404)

    # -- CORS preflight --
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "86400")
        self.end_headers()

    # -- GET --
    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")

        if path == "/api/listeners/count":
            self._json({"active_unique_listeners": listener_count()})
            return

        # /share/<id>
        if path.startswith("/share/"):
            sid = path[7:]
            snap = load_snapshot(sid)
            if not snap:
                self._not_found()
                return
            self._html(share_page_html(snap, sid))
            return

        # /og/<id>.png
        if path.startswith("/og/") and path.endswith(".png"):
            sid = path[4:-4]
            img = get_og_image_path(sid)
            if not img or not os.path.isfile(img):
                self._not_found()
                return
            with open(img, "rb") as f:
                data = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        self._not_found()

    # -- POST --
    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")

        if path == "/api/listeners/heartbeat":
            body = self._read_body()
            sid = body.get("session_id", "")
            if not sid or len(sid) > 100:
                self._json({"error": "invalid session_id"}, 400)
                return
            listener_heartbeat(sid)
            self._json({"ok": True})
            return

        if path == "/api/share/snapshot":
            result = create_snapshot()
            if not result:
                self._json({"error": "no now-playing data"}, 500)
                return
            self._json(result)
            return

        self._not_found()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    os.makedirs(SNAPSHOTS_DIR, exist_ok=True)
    os.makedirs(OG_DIR, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Radio API listening on 127.0.0.1:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n[{time.strftime('%Y-%m-%dT%H:%M:%S')}] Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
