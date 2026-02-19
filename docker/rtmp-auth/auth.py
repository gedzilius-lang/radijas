#!/usr/bin/env python3
"""
RTMP stream-key auth server.
nginx-rtmp on_publish sends POST body (application/x-www-form-urlencoded)
with fields: call, name, app, addr, clientid, ...
We validate the 'name' field against allowed stream keys.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs
import os

# Accepted stream keys (bare key or path/key format from full URL)
VALID_KEYS = {"people", "pwl-live-2024"}


class AuthHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", errors="ignore")
        params = parse_qs(body, keep_blank_values=True)

        name = params.get("name", [""])[0]
        # Accept both "people" and "live/people" path formats
        key = name.split("/")[-1] if "/" in name else name

        if key in VALID_KEYS:
            print(f"[auth] ALLOW  app={params.get('app',['?'])[0]!r} name={name!r}", flush=True)
            self.send_response(200)
        else:
            print(f"[auth] REJECT app={params.get('app',['?'])[0]!r} name={name!r}", flush=True)
            self.send_response(403)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # suppress default access log (we log above)


if __name__ == "__main__":
    port = int(os.environ.get("AUTH_PORT", 8088))
    print(f"[auth] Listening on 0.0.0.0:{port}", flush=True)
    HTTPServer(("0.0.0.0", port), AuthHandler).serve_forever()
