## Instruction block for Claude Code (paste into your repo as `RADIO_AGENT_INSTRUCTIONS.md` or into the prompt)

Claude Code must:

1. **Clone + read the repository first** (README, any `/radio` or `/infra` folders, nginx configs, systemd units, scripts). The repo is the *base spec*.
2. **Not be limited to repo content**: if the repo is missing working details, Claude must use prior operational knowledge to produce a *complete, reproducible build* for a fresh VPS—while keeping the repo's intent and requirements unchanged.
3. **Hard invariants (do not break):**

   * One public HLS endpoint that the website always loads: `https://radio.peoplewelike.club/hls/current/index.m3u8`.
   * Two HLS sources (`/hls/live` and `/hls/autodj`) plus a **relay layer** that generates monotonic segment names + discontinuity markers to switch without refresh.
   * Live ingest via RTMP on `:1935`, and AutoDJ always running so the relay always has segments.
4. **Output must be "root-shell paste blocks"** grouped by component:

   * Preflight + OS packages
   * nginx + rtmp config + safe default vhost (prevents wrong-host redirects)
   * Directories + permissions
   * Liquidsoap AutoDJ (audio-only to internal RTMP)
   * FFmpeg overlay publisher (MP4 loop + audio → RTMP autodj)
   * RTMP stats endpoint (localhost)
   * Switch daemon (`radio-switchd`)
   * Relay daemon (`radio-hls-relay`)
   * Systemd units enable/start
   * Verification commands + live ingest credentials
5. Every config change must run `nginx -t` (and fail fast if invalid).

---

# Fresh VPS install: copy/paste blocks (root shell)

These blocks implement the known-good architecture: nginx-rtmp generates HLS for **live** and **autodj**, `radio-switchd` decides active mode, and `radio-hls-relay` builds a stable `/hls/current` playlist that switches without refresh.

---

## 0) Variables (edit once, then paste)

```bash
export DOMAIN="radio.peoplewelike.club"
export EMAIL="admin@peoplewelike.club"   # used only if you run certbot HTTP
export HLS_ROOT="/var/www/hls"
```

---

## 1) System prep + packages + firewall

```bash
set -euo pipefail

apt-get update -y
apt-get upgrade -y

apt-get install -y \
  nginx libnginx-mod-rtmp \
  ffmpeg \
  liquidsoap \
  python3 \
  python3-venv \
  curl \
  jq \
  ca-certificates \
  ufw \
  unzip

# Basic firewall (adjust if you use a non-22 SSH port)
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 1935/tcp
ufw --force enable

systemctl enable --now nginx
```

---

## 2) Directory layout + permissions

```bash
set -euo pipefail

mkdir -p "${HLS_ROOT}/"{live,autodj,current,placeholder}
mkdir -p /var/lib/liquidsoap
mkdir -p /var/www/radio
mkdir -p /var/www/radio/data
mkdir -p /run/radio
mkdir -p /var/lib/radio-hls-relay

chown -R www-data:www-data "${HLS_ROOT}" /var/www/radio
chmod -R 775 "${HLS_ROOT}" /var/www/radio

# Placeholder so /hls/current isn't empty on first boot (optional)
echo "ok" > "${HLS_ROOT}/placeholder/README.txt"
```

---

## 3) Nginx: safe default server (prevents wrong-host collisions)

This avoids the class of bugs where the "wrong" vhost becomes default and redirects you to an unrelated hostname.

```bash
set -euo pipefail

cat > /etc/nginx/sites-available/00-default.conf <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  return 444;
}
EOF

ln -sf /etc/nginx/sites-available/00-default.conf /etc/nginx/sites-enabled/00-default.conf

# Remove distro default if present
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl reload nginx
```

---

## 4) Nginx: RTMP core config (`/etc/nginx/rtmp.conf`)

Matches the working layout: live → `/hls/live`, autodj → `/hls/autodj`, plus internal `autodj_audio`.

```bash
set -euo pipefail

cat > /etc/nginx/rtmp.conf <<EOF
rtmp {
  server {
    listen 1935;
    chunk_size 4096;

    application live {
      live on;

      hls on;
      hls_path ${HLS_ROOT}/live;
      hls_fragment 6s;
      hls_playlist_length 120s;
      hls_cleanup on;
      hls_continuous on;

      exec_publish /usr/local/bin/hls-switch live;
      exec_publish_done /usr/local/bin/hls-switch autodj;
    }

    application autodj_audio {
      live on;
      record off;

      allow publish 127.0.0.1;
      deny  publish all;

      allow play 127.0.0.1;
      deny  play all;
    }

    application autodj {
      live on;

      allow publish 127.0.0.1;
      deny  publish all;

      hls on;
      hls_path ${HLS_ROOT}/autodj;
      hls_fragment 6;
      hls_playlist_length 120;
      hls_cleanup on;
      hls_continuous on;
    }
  }
}
EOF
```

---

## 5) Nginx: HTTP vhost for HLS + site (`/etc/nginx/sites-available/radio.conf`)

```bash
set -euo pipefail

cat > /etc/nginx/sites-available/radio.conf <<EOF
server {
  listen 80;
  server_name ${DOMAIN};

  root /var/www/radio;

  add_header Access-Control-Allow-Origin "*" always;

  location /hls/ {
    types {
      application/vnd.apple.mpegurl m3u8;
      video/mp2t ts;
    }
    add_header Cache-Control "no-cache, no-store, must-revalidate" always;
    add_header Pragma "no-cache" always;
    add_header Expires "0" always;
    try_files \$uri =404;
  }

  location / {
    try_files \$uri \$uri/ =404;
  }
}
EOF

ln -sf /etc/nginx/sites-available/radio.conf /etc/nginx/sites-enabled/radio.conf

# Ensure nginx loads rtmp.conf
grep -q 'include /etc/nginx/rtmp.conf;' /etc/nginx/nginx.conf || \
  sed -i '1i\include /etc/nginx/rtmp.conf;\n' /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx
```

---

## 6) RTMP stats endpoint (localhost) for live detection

`radio-switchd` uses this to read `<nclients>` for the `live` app.

```bash
set -euo pipefail

cat > /etc/nginx/conf.d/rtmp_stat.conf <<'EOF'
server {
  listen 127.0.0.1:8089;
  server_name localhost;

  location /rtmp_stat {
    rtmp_stat all;
    rtmp_stat_stylesheet stat.xsl;
  }

  location /stat.xsl {
    root /usr/share/nginx/html;
  }
}
EOF

nginx -t
systemctl reload nginx

curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 5
```

---

## 7) Liquidsoap AutoDJ (audio-only → internal RTMP `autodj_audio`)

This is the minimal AutoDJ engine that continuously pushes audio into nginx-rtmp.

```bash
set -euo pipefail

# Create a service user if not present
id liquidsoap >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin liquidsoap

mkdir -p /etc/liquidsoap /var/lib/liquidsoap /var/www/radio/data
chown -R liquidsoap:liquidsoap /var/lib/liquidsoap
chown -R www-data:www-data /var/www/radio/data

# AutoDJ playlist directory (upload MP3s here via SFTP/scp)
mkdir -p /var/lib/liquidsoap/music
chown -R liquidsoap:liquidsoap /var/lib/liquidsoap/music

cat > /etc/liquidsoap/radio.liq <<'EOF'
settings.init.allow_root.set(true)
settings.log.stdout.set(true)

# Watch directory for music uploads
music = playlist(mode="random", reload_mode="watch", "/var/lib/liquidsoap/music")

# Optional: basic crossfade for smoother playback
s = crossfade(duration=2.0, music)

# Push audio-only to internal RTMP app autodj_audio as "stream"
output.url(
  fallible=true,
  url="rtmp://127.0.0.1:1935/autodj_audio/stream",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", ar=44100, channels=2)),
  s
)
EOF
```

---

## 8) FFmpeg overlay publisher (`autodj-video-overlay`)

Loops MP4 and combines with the internal audio feed to publish a program stream into `autodj`, producing HLS segments. Keyframe cadence is aligned to fragment duration (6s).

```bash
set -euo pipefail

# Put your loop mp4 here:
# /var/lib/liquidsoap/loop.mp4
# (Upload it; must exist before overlay service will stay healthy.)

cat > /usr/local/bin/autodj-video-overlay <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOOP_MP4="/var/lib/liquidsoap/loop.mp4"
AUDIO_IN="rtmp://127.0.0.1:1935/autodj_audio/stream?live=1"
OUT="rtmp://127.0.0.1:1935/autodj/index"

FPS=25
FRAG=6
GOP=$((FPS*FRAG))   # 150
FORCE_KF="expr:gte(t,n_forced*${FRAG})"

log(){ echo "[$(date -Is)] $*"; }

[[ -f "$LOOP_MP4" ]] || { log "Missing loop mp4: $LOOP_MP4"; exit 1; }

log "Starting overlay publish"
log "Audio in: $AUDIO_IN"
log "Out:      $OUT"

exec ffmpeg -hide_banner -loglevel warning \
  -re -stream_loop -1 -i "$LOOP_MP4" \
  -thread_queue_size 1024 -i "$AUDIO_IN" \
  -map 0:v:0 -map 1:a:0 \
  -vf "scale=854:-2,fps=${FPS}" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -r "${FPS}" -g "${GOP}" -keyint_min "${GOP}" -sc_threshold 0 \
  -force_key_frames "${FORCE_KF}" \
  -b:v 1200k -maxrate 1200k -bufsize 2400k \
  -x264-params "nal-hrd=cbr:force-cfr=1:repeat-headers=1" \
  -c:a aac -b:a 128k -ar 44100 -ac 2 \
  -muxdelay 0 -muxpreload 0 \
  -flvflags no_duration_filesize \
  -f flv "$OUT"
EOF

chmod +x /usr/local/bin/autodj-video-overlay
```

---

## 9) Switch + Relay (the "no refresh switching" core)

These are the known-good scripts: `radio-switchd` writes `live|autodj` to `/run/radio/active`, and `radio-hls-relay` generates `/hls/current/index.m3u8` with monotonic `seg-N.ts` names + discontinuity markers.

### 9.1 `hls-switch` (kept for RTMP publish hooks; should not be the public truth)

```bash
set -euo pipefail

cat > /usr/local/bin/hls-switch <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HLS_ROOT="/var/www/hls"
AUTODJ_DIR="$HLS_ROOT/autodj"
LIVE_DIR="$HLS_ROOT/live"
PLACEHOLDER_DIR="$HLS_ROOT/placeholder"
CURRENT="$HLS_ROOT/current"

mode="${1:-}"
lock="/run/hls-switch.lock"

has_real_ts() {
  local m3u8="$1"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8"
}

do_switch() {
  local target="$1"
  ln -sfn "$target" "$CURRENT"
  chown -h www-data:www-data "$CURRENT" 2>/dev/null || true
}

(
  flock -w 10 9

  case "$mode" in
    autodj) do_switch "$AUTODJ_DIR" ;;
    live)
      for i in {1..10}; do
        if has_real_ts "$LIVE_DIR/index.m3u8"; then
          do_switch "$LIVE_DIR"
          exit 0
        fi
        sleep 1
      done
      do_switch "$AUTODJ_DIR"
      ;;
    placeholder) do_switch "$PLACEHOLDER_DIR" ;;
    *) echo "Usage: hls-switch {autodj|live|placeholder}" >&2; exit 2 ;;
  esac
) 9>"$lock"
EOF

chmod +x /usr/local/bin/hls-switch
```

### 9.2 `radio-switchd`

```bash
set -euo pipefail

cat > /usr/local/bin/radio-switchd <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HLS_ROOT="/var/www/hls"
LIVE_DIR="$HLS_ROOT/live"

ACTIVE_DIR="/run/radio"
ACTIVE_FILE="$ACTIVE_DIR/active"

RTMP_STAT_URL="http://127.0.0.1:8089/rtmp_stat"

log(){ echo "[$(date -Is)] $*"; }

latest_ts() {
  local m3u8="$1"
  awk '/^index-[0-9]+\.ts$/{s=$0} END{print s}' "$m3u8"
}

mtime_age_s() {
  local f="$1"
  local now m
  now="$(date +%s)"
  m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  echo $(( now - m ))
}

live_nclients() {
  curl -fsS "$RTMP_STAT_URL" 2>/dev/null | awk '
    $0 ~ /<application>/ {inapp=1; name=""}
    inapp && $0 ~ /<name>live<\/name>/ {name="live"}
    name=="live" && $0 ~ /<nclients>/ {
      gsub(/.*<nclients>|<\/nclients>.*/,"",$0); print $0; exit
    }
  ' | tr -d '\r' | awk '{print ($1==""?0:$1)}'
}

set_active() {
  local v="$1"
  mkdir -p "$ACTIVE_DIR"
  printf "%s\n" "$v" >"${ACTIVE_FILE}.tmp"
  mv "${ACTIVE_FILE}.tmp" "$ACTIVE_FILE"
}

is_live_healthy() {
  local m3u8 ts age lc
  m3u8="$LIVE_DIR/index.m3u8"
  [[ -f "$m3u8" ]] || return 1
  grep -qE '^index-[0-9]+\.ts$' "$m3u8" || return 1
  ts="$(latest_ts "$m3u8")"
  [[ -n "$ts" ]] || return 1
  [[ -f "$LIVE_DIR/$ts" ]] || return 1

  age="$(mtime_age_s "$m3u8")"
  lc="$(live_nclients || echo 0)"

  if [[ "${lc:-0}" -gt 0 ]]; then return 0; fi
  if [[ "$age" -le 8 ]]; then return 0; fi
  return 1
}

last=""
while true; do
  if is_live_healthy; then
    if [[ "$last" != "live" ]]; then
      set_active "live"
      last="live"
      log "ACTIVE -> live"
    fi
  else
    if [[ "$last" != "autodj" ]]; then
      set_active "autodj"
      last="autodj"
      log "ACTIVE -> autodj"
    fi
  fi
  sleep 1
done
EOF

chmod +x /usr/local/bin/radio-switchd
```

### 9.3 `radio-hls-relay`

```bash
set -euo pipefail

cat > /usr/local/bin/radio-hls-relay <<'EOF'
#!/usr/bin/env python3
import os, time, json, math

HLS_ROOT="/var/www/hls"
SRC = {
  "autodj": os.path.join(HLS_ROOT, "autodj"),
  "live":   os.path.join(HLS_ROOT, "live"),
}
OUT_DIR = os.path.join(HLS_ROOT, "current")
OUT_M3U8 = os.path.join(OUT_DIR, "index.m3u8")

ACTIVE_FILE="/run/radio/active"
STATE_FILE="/var/lib/radio-hls-relay/state.json"

WINDOW_SEGMENTS = 10
POLL = 0.5

def read_active():
  try:
    v = open(ACTIVE_FILE,"r").read().strip()
    return v if v in SRC else "autodj"
  except Exception:
    return "autodj"

def parse_m3u8(path):
  segs=[]
  dur=None
  try:
    with open(path,"r") as f:
      for line in f:
        line=line.strip()
        if line.startswith("#EXTINF:"):
          try:
            dur=float(line.split(":",1)[1].split(",",1)[0])
          except Exception:
            dur=None
        elif line.startswith("index-") and line.endswith(".ts"):
          if dur is None:
            dur=6.0
          segs.append((dur, line))
          dur=None
  except FileNotFoundError:
    return []
  return segs

def safe_stat(p):
  try:
    st=os.stat(p)
    return int(st.st_mtime), int(st.st_size)
  except Exception:
    return None

def load_state():
  try:
    with open(STATE_FILE,"r") as f:
      return json.load(f)
  except Exception:
    return {"next_seq": 0, "map": {}, "window": [], "last_src": None}

def save_state(st):
  tmp=STATE_FILE+".tmp"
  with open(tmp,"w") as f:
    json.dump(st,f)
  os.replace(tmp, STATE_FILE)

def ensure_symlink(link_path, target_path):
  try:
    if os.path.islink(link_path) or os.path.exists(link_path):
      if os.path.islink(link_path) and os.readlink(link_path) == target_path:
        return
      os.unlink(link_path)
  except FileNotFoundError:
    pass
  os.symlink(target_path, link_path)

def write_playlist(window):
  if not window:
    return
  maxdur=max([w["dur"] for w in window] + [6.0])
  target=int(math.ceil(maxdur))

  first_seq=window[0]["seq"]
  lines=[
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    f"#EXT-X-TARGETDURATION:{target}",
    f"#EXT-X-MEDIA-SEQUENCE:{first_seq}",
  ]

  for w in window:
    if w.get("disc"):
      lines.append("#EXT-X-DISCONTINUITY")
    lines.append(f"#EXTINF:{w['dur']:.3f},")
    lines.append(f"seg-{w['seq']}.ts")

  tmp=OUT_M3U8+".tmp"
  with open(tmp,"w") as f:
    f.write("\n".join(lines)+"\n")
  os.replace(tmp, OUT_M3U8)

def cleanup_symlinks(window):
  keep=set([f"seg-{w['seq']}.ts" for w in window] + ["index.m3u8"])
  try:
    for name in os.listdir(OUT_DIR):
      if name not in keep and name.startswith("seg-") and name.endswith(".ts"):
        try:
          os.unlink(os.path.join(OUT_DIR,name))
        except Exception:
          pass
  except Exception:
    pass

def main():
  os.makedirs(OUT_DIR, exist_ok=True)
  os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
  st=load_state()

  while True:
    src=read_active()
    src_dir=SRC[src]
    src_m3u8=os.path.join(src_dir, "index.m3u8")

    segs=parse_m3u8(src_m3u8)[-WINDOW_SEGMENTS:]
    source_changed = (st.get("last_src") is not None and st.get("last_src") != src)

    for dur, segname in segs:
      src_seg=os.path.join(src_dir, segname)
      ss=safe_stat(src_seg)
      if not ss:
        continue
      mtime,size=ss
      key=f"{src}:{segname}:{mtime}:{size}"
      if key not in st["map"]:
        seq=st["next_seq"]
        st["next_seq"] += 1
        st["map"][key]={"seq":seq,"dur":float(dur)}

        disc = False
        if source_changed:
          disc = True
          source_changed = False

        st["window"].append({"seq":seq,"dur":float(dur),"disc":disc})
        ensure_symlink(os.path.join(OUT_DIR, f"seg-{seq}.ts"), src_seg)

    if len(st["window"]) > WINDOW_SEGMENTS:
      st["window"] = st["window"][-WINDOW_SEGMENTS:]

    if st["window"]:
      write_playlist(st["window"])
      cleanup_symlinks(st["window"])

    st["last_src"]=src
    save_state(st)
    time.sleep(POLL)

if __name__ == "__main__":
  main()
EOF

chmod +x /usr/local/bin/radio-hls-relay
```

---

## 10) systemd units (4 core services)

These are the exact service roles described in the working manual.

```bash
set -euo pipefail

cat > /etc/systemd/system/liquidsoap-autodj.service <<'EOF'
[Unit]
Description=Liquidsoap AutoDJ (audio-only) -> nginx-rtmp
After=network.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=liquidsoap
Group=liquidsoap
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/radio.liq
Restart=always
RestartSec=2
Nice=10
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/liquidsoap /var/www/radio/data

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/autodj-video-overlay.service <<'EOF'
[Unit]
Description=AutoDJ Overlay: loop MP4 video + AutoDJ audio -> nginx-rtmp autodj/index
After=network.target nginx.service liquidsoap-autodj.service
Wants=nginx.service liquidsoap-autodj.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStart=/usr/local/bin/autodj-video-overlay
Restart=always
RestartSec=2
KillSignal=SIGINT
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/radio-switchd.service <<'EOF'
[Unit]
Description=Radio switch daemon (LIVE <-> AutoDJ) every 1s
After=nginx.service
Wants=nginx.service

[Service]
Type=simple
ExecStart=/usr/local/bin/radio-switchd
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/radio-hls-relay.service <<'EOF'
[Unit]
Description=Radio HLS relay (stable /hls/current playlist for seamless switching)
After=nginx.service radio-switchd.service
Wants=nginx.service radio-switchd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/radio-hls-relay
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay
systemctl --no-pager status liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay
```

---

## 11) TLS (choose ONE)

### Option A: Certbot HTTP (requires DNS A record to this VPS and port 80 reachable)

```bash
set -euo pipefail
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d "${DOMAIN}" -m "${EMAIL}" --agree-tos --non-interactive
nginx -t
systemctl reload nginx
```

### Option B: Cloudflare DNS-01 (preferred if proxied / orange-cloud)

Use your existing Cloudflare DNS-01 method if that's how the rest of your stack is done (this depends on your token + tooling; keep it consistent with your infra).

---

## 12) Live ingest credentials (what to put into OBS / Blackmagic)

From the working build:

* **RTMP server**: `rtmp://radio.peoplewelike.club:1935/live`
* **Stream key**: `index`
* Full publish URL: `rtmp://radio.peoplewelike.club:1935/live/index`

AutoDJ is internal-only and must publish from localhost; do not expose its publish endpoints publicly.

---

## 13) Verification (copy/paste)

```bash
set -euo pipefail

echo "=== Services ==="
systemctl is-active liquidsoap-autodj autodj-video-overlay radio-switchd radio-hls-relay

echo "=== RTMP stat (must return XML) ==="
curl -fsS http://127.0.0.1:8089/rtmp_stat | head -n 20

echo "=== Source HLS folders ==="
ls -lah /var/www/hls/autodj | head || true
ls -lah /var/www/hls/live   | head || true

echo "=== Current relay playlist (should exist once autodj is producing) ==="
ls -lah /var/www/hls/current | head || true
head -n 30 /var/www/hls/current/index.m3u8 || true

echo "=== Active mode ==="
cat /run/radio/active || true
```

---

## Operational notes (non-optional)

* `/var/www/hls/current` must be a **directory**, because the relay writes `index.m3u8` and symlinks `seg-*.ts` into it. The relay is the real mechanism; do not rely on symlink flipping as the public switch method.
* If the player ever "loads forever" on switching, it's almost always because the public URL is not the relay playlist or segment naming resets (the relay prevents this).
* If you see a wrong-host redirect again, it's because nginx default server / vhost priority is wrong; keep the `00-default.conf` returning `444` and ensure `server_name radio.peoplewelike.club` is the only public radio vhost. (This is the specific failure mode you've been hitting.)

If you want, paste the repo URL (or the repo's `/radio` folder tree) and I'll adapt the blocks so they match the repository's exact paths while keeping the working invariants above.
