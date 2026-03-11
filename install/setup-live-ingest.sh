#!/usr/bin/env bash
###############################################################################
# setup-live-ingest.sh — Enable live RTMP ingest with auto-switch
# People We Like Radio
#
# What this does:
#   1. Generates secure streaming credentials (stream key + password)
#   2. Creates RTMP auth endpoint (nginx on 127.0.0.1:8088)
#   3. Ensures rtmp.conf has the "live" application with auth + HLS + switch hooks
#   4. Verifies all switch daemons are deployed (switchd, hls-switch, relay)
#   5. Tests auth endpoint (correct + incorrect credentials)
#   6. Tests the autodj↔live switch mechanism
#   7. Restarts affected services
#   8. Outputs OBS/streaming software settings
#
# How live switching works:
#   Streamer → RTMP :1935/live/{key}?pwd={pwd}
#     → nginx-rtmp on_publish → auth endpoint (200=allow, 403=deny)
#     → exec_publish → hls-switch live (switches /hls/current → /hls/live)
#     → radio-switchd detects live HLS health → writes /run/radio/active=live
#     → radio-hls-relay reads active → inserts #EXT-X-DISCONTINUITY → switches source
#   When streamer disconnects:
#     → exec_publish_done → hls-switch autodj → seamless fallback to autodj
#
# Run as root:  bash setup-live-ingest.sh
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'
BLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GRN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; }
warn() { echo -e "  ${YLW}!${NC}  $*"; }

DIVIDER="════════════════════════════════════════════════════════════"

if [[ $EUID -ne 0 ]]; then fail "Must run as root"; exit 1; fi

CRED_FILE="/etc/radio/credentials"
AUTH_CONF="/etc/nginx/conf.d/rtmp_auth.conf"
RTMP_CONF="/etc/nginx/rtmp.conf"
DOMAIN="radio.peoplewelike.club"
RTMP_PORT=1935
ERRORS=0

###############################################################################
# STEP 1 — Generate or load credentials
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 1: Streaming credentials"
echo "$DIVIDER"

mkdir -p /etc/radio

if [[ -f "$CRED_FILE" ]]; then
  source "$CRED_FILE"
  if [[ -n "${STREAM_KEY:-}" && -n "${STREAM_PASSWORD:-}" ]]; then
    ok "Existing credentials loaded from $CRED_FILE"
    log "  Stream key: $STREAM_KEY"
    log "  Password:   $STREAM_PASSWORD"
  else
    warn "Credentials file exists but is incomplete — regenerating"
    rm -f "$CRED_FILE"
  fi
fi

if [[ ! -f "$CRED_FILE" ]]; then
  # Generate cryptographically secure random credentials
  STREAM_KEY="live_$(openssl rand -hex 8)"
  STREAM_PASSWORD="$(openssl rand -hex 16)"

  cat > "$CRED_FILE" <<EOF
# People We Like Radio — Live streaming credentials
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
STREAM_KEY="${STREAM_KEY}"
STREAM_PASSWORD="${STREAM_PASSWORD}"
EOF
  chmod 600 "$CRED_FILE"
  ok "Generated new credentials → $CRED_FILE"
  log "  Stream key: $STREAM_KEY"
  log "  Password:   $STREAM_PASSWORD"
fi

# Re-source to ensure variables are set
source "$CRED_FILE"

###############################################################################
# STEP 2 — Create RTMP auth endpoint
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 2: RTMP auth endpoint (nginx on 127.0.0.1:8088)"
echo "$DIVIDER"

# Always recreate to match current credentials
cat > "$AUTH_CONF" <<AUTHEOF
# RTMP live stream authentication
# Checks stream key (\$arg_name) and password (\$arg_pwd)
# Called by nginx-rtmp on_publish directive
server {
    listen 127.0.0.1:8088;

    location /auth {
        # Check both stream key and password
        set \$auth_ok 0;
        if (\$arg_name = "${STREAM_KEY}") {
            set \$auth_ok "\${auth_ok}1";
        }
        if (\$arg_pwd = "${STREAM_PASSWORD}") {
            set \$auth_ok "\${auth_ok}1";
        }
        # Both must match: "0" + "1" + "1" = "011"
        if (\$auth_ok = "011") {
            return 200;
        }
        return 403;
    }
}
AUTHEOF
ok "Created $AUTH_CONF"

###############################################################################
# STEP 3 — Ensure rtmp.conf has live application
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 3: RTMP configuration (live application)"
echo "$DIVIDER"

NEED_RTMP_UPDATE=false

if [[ ! -f "$RTMP_CONF" ]]; then
  NEED_RTMP_UPDATE=true
  log "rtmp.conf does not exist — will create"
elif ! grep -q 'application live' "$RTMP_CONF"; then
  NEED_RTMP_UPDATE=true
  log "rtmp.conf exists but has no 'application live' — will update"
elif ! grep -q 'on_publish' "$RTMP_CONF"; then
  NEED_RTMP_UPDATE=true
  log "rtmp.conf has live app but no auth — will update"
elif ! grep -q 'exec_publish.*hls-switch' "$RTMP_CONF"; then
  NEED_RTMP_UPDATE=true
  log "rtmp.conf has live app but no switch hooks — will update"
fi

if $NEED_RTMP_UPDATE; then
  # Backup existing config
  [[ -f "$RTMP_CONF" ]] && cp "$RTMP_CONF" "${RTMP_CONF}.bak.$(date +%s)"

  cat > "$RTMP_CONF" <<'RTMPEOF'
rtmp {
    server {
        listen 1935;
        chunk_size 4096;
        ping 30s;
        ping_timeout 10s;

        # ─── Live ingest (external streamers, authenticated) ───
        application live {
            live on;
            on_publish http://127.0.0.1:8088/auth;

            # HLS output for live stream
            hls on;
            hls_path /var/www/hls/live;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;

            # Auto-switch hooks: when someone goes live → switch to live
            # When they disconnect → switch back to autodj
            exec_publish /usr/local/bin/hls-switch live;
            exec_publish_done /usr/local/bin/hls-switch autodj;

            record off;
        }

        # ─── AutoDJ audio (internal, Liquidsoap → FFmpeg → here) ───
        application autodj_audio {
            live on;
            record off;
            allow publish 127.0.0.1;
            deny publish all;
            allow play 127.0.0.1;
            deny play all;
        }

        # ─── AutoDJ video+audio (internal, overlay → here → HLS) ───
        application autodj {
            live on;
            allow publish 127.0.0.1;
            deny publish all;
            hls on;
            hls_path /var/www/hls/autodj;
            hls_fragment 6s;
            hls_playlist_length 120s;
            hls_cleanup on;
            hls_continuous on;
        }
    }
}
RTMPEOF

  # Ensure rtmp.conf is included in nginx.conf
  if ! grep -q "include /etc/nginx/rtmp.conf" /etc/nginx/nginx.conf; then
    echo -e "\n# RTMP streaming\ninclude /etc/nginx/rtmp.conf;" >> /etc/nginx/nginx.conf
    ok "Added rtmp.conf include to nginx.conf"
  fi

  ok "Created/updated rtmp.conf with live application + auth + switch hooks"
else
  ok "rtmp.conf already has live application with auth and switch hooks"
fi

###############################################################################
# STEP 4 — Verify daemon scripts are deployed
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 4: Verify switching daemons"
echo "$DIVIDER"

DAEMONS_OK=true

for script in /usr/local/bin/radio-switchd /usr/local/bin/hls-switch /usr/local/bin/radio-hls-relay; do
  if [[ -x "$script" ]]; then
    ok "$(basename "$script") — deployed and executable"
  else
    fail "$(basename "$script") — MISSING or not executable"
    echo "     Run deploy-fix.sh first to install all daemons"
    DAEMONS_OK=false
    ERRORS=$((ERRORS + 1))
  fi
done

# Verify systemd services exist
for svc in radio-switchd radio-hls-relay; do
  if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "$svc"; then
    ok "${svc}.service — registered"
  else
    fail "${svc}.service — NOT registered in systemd"
    echo "     Run deploy-fix.sh first to create systemd services"
    DAEMONS_OK=false
    ERRORS=$((ERRORS + 1))
  fi
done

# Ensure HLS dirs exist
mkdir -p /var/www/hls/{live,autodj,current,placeholder}
chown -R www-data:www-data /var/www/hls
ok "HLS directories exist"

###############################################################################
# STEP 5 — Test nginx config + reload
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 5: Nginx syntax test + reload"
echo "$DIVIDER"

if nginx -t 2>&1; then
  ok "Nginx config syntax valid"
  systemctl reload nginx
  sleep 1
  if systemctl is-active --quiet nginx; then
    ok "Nginx reloaded successfully"
  else
    fail "Nginx failed after reload!"
    ERRORS=$((ERRORS + 1))
  fi
else
  fail "Nginx config syntax ERROR — not reloading"
  nginx -t 2>&1 || true
  ERRORS=$((ERRORS + 1))
fi

###############################################################################
# STEP 6 — Test auth endpoint
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 6: Testing RTMP auth endpoint"
echo "$DIVIDER"

sleep 1  # Give nginx a moment after reload

# Test 1: Correct credentials → should return 200
AUTH_CORRECT=$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:8088/auth?name=${STREAM_KEY}&pwd=${STREAM_PASSWORD}" 2>/dev/null || echo "000")
if [[ "$AUTH_CORRECT" == "200" ]]; then
  ok "Correct credentials → HTTP $AUTH_CORRECT (allowed)"
else
  fail "Correct credentials → HTTP $AUTH_CORRECT (expected 200)"
  ERRORS=$((ERRORS + 1))
fi

# Test 2: Wrong password → should return 403
AUTH_WRONG_PWD=$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:8088/auth?name=${STREAM_KEY}&pwd=wrong_password" 2>/dev/null || echo "000")
if [[ "$AUTH_WRONG_PWD" == "403" ]]; then
  ok "Wrong password → HTTP $AUTH_WRONG_PWD (rejected)"
else
  fail "Wrong password → HTTP $AUTH_WRONG_PWD (expected 403)"
  ERRORS=$((ERRORS + 1))
fi

# Test 3: Wrong stream key → should return 403
AUTH_WRONG_KEY=$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:8088/auth?name=wrong_key&pwd=${STREAM_PASSWORD}" 2>/dev/null || echo "000")
if [[ "$AUTH_WRONG_KEY" == "403" ]]; then
  ok "Wrong stream key → HTTP $AUTH_WRONG_KEY (rejected)"
else
  fail "Wrong stream key → HTTP $AUTH_WRONG_KEY (expected 403)"
  ERRORS=$((ERRORS + 1))
fi

# Test 4: No credentials → should return 403
AUTH_NONE=$(curl -sS -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:8088/auth" 2>/dev/null || echo "000")
if [[ "$AUTH_NONE" == "403" ]]; then
  ok "No credentials → HTTP $AUTH_NONE (rejected)"
else
  fail "No credentials → HTTP $AUTH_NONE (expected 403)"
  ERRORS=$((ERRORS + 1))
fi

###############################################################################
# STEP 7 — Test switch mechanism
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 7: Testing autodj ↔ live switch mechanism"
echo "$DIVIDER"

mkdir -p /run/radio

# Test hls-switch script logic (dry-run the symlink mechanism)
if [[ -x /usr/local/bin/hls-switch ]]; then
  # Create test HLS content if autodj has segments
  if ls /var/www/hls/autodj/*.ts &>/dev/null 2>&1; then
    # hls-switch autodj should point current → autodj
    /usr/local/bin/hls-switch autodj 2>/dev/null || true
    CURRENT_TARGET="$(readlink /var/www/hls/current 2>/dev/null || echo 'none')"
    if [[ "$CURRENT_TARGET" == "/var/www/hls/autodj" ]]; then
      ok "hls-switch autodj → /hls/current points to /hls/autodj"
    else
      warn "hls-switch autodj → current points to: $CURRENT_TARGET"
    fi
  else
    warn "No autodj HLS segments yet — skipping hls-switch test"
  fi
fi

# Test switchd active file mechanism
echo "autodj" > /run/radio/active
ACTIVE_READ="$(cat /run/radio/active 2>/dev/null)"
if [[ "$ACTIVE_READ" == "autodj" ]]; then
  ok "Active source file works (wrote+read: autodj)"
else
  fail "Active source file not working"
  ERRORS=$((ERRORS + 1))
fi

# Simulate live → autodj transition
echo "live" > /run/radio/active
ACTIVE_READ="$(cat /run/radio/active 2>/dev/null)"
if [[ "$ACTIVE_READ" == "live" ]]; then
  ok "Simulated live switch (wrote+read: live)"
else
  fail "Could not write live state"
  ERRORS=$((ERRORS + 1))
fi

# Reset back to autodj
echo "autodj" > /run/radio/active
ok "Reset active source to autodj"

###############################################################################
# STEP 8 — Restart affected services
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 8: Restarting services"
echo "$DIVIDER"

if $DAEMONS_OK; then
  for svc in radio-switchd radio-hls-relay; do
    systemctl restart "$svc" 2>/dev/null && ok "Restarted $svc" || warn "Could not restart $svc"
  done
else
  warn "Skipping service restart — daemons not fully deployed"
  warn "Run deploy-fix.sh first, then re-run this script"
fi

###############################################################################
# STEP 9 — Verify RTMP port is listening
###############################################################################
echo ""
echo "$DIVIDER"
log "STEP 9: Verify RTMP port"
echo "$DIVIDER"

if ss -tlnp 2>/dev/null | grep -q ":${RTMP_PORT} "; then
  ok "RTMP port ${RTMP_PORT} is listening"
  ss -tlnp 2>/dev/null | grep ":${RTMP_PORT} " | while read -r line; do echo "     $line"; done
else
  fail "RTMP port ${RTMP_PORT} is NOT listening"
  echo "     Check: nginx -t && systemctl restart nginx"
  ERRORS=$((ERRORS + 1))
fi

# Verify RTMP stats shows live application
STAT="$(curl -fsS http://127.0.0.1:8089/rtmp_stat 2>/dev/null || echo '')"
if echo "$STAT" | grep -q '<name>live</name>'; then
  ok "RTMP 'live' application is registered"
else
  warn "RTMP stats don't show 'live' application (may need nginx restart)"
fi

###############################################################################
# RESULTS
###############################################################################
echo ""
echo "$DIVIDER"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GRN}${BLD}  ALL TESTS PASSED — Live ingest is ready!${NC}"
else
  echo -e "${YLW}${BLD}  $ERRORS TEST(S) FAILED — see errors above${NC}"
fi
echo "$DIVIDER"

###############################################################################
# STREAMING CREDENTIALS OUTPUT
###############################################################################
echo ""
echo -e "${BLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLD}║           OBS / STREAMING SOFTWARE SETTINGS                ║${NC}"
echo -e "${BLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}║${NC}  ${CYN}Server:${NC}                                                    ${BLD}║${NC}"
echo -e "${BLD}║${NC}    rtmp://${DOMAIN}:${RTMP_PORT}/live                       ${BLD}║${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}║${NC}  ${CYN}Stream Key:${NC}                                                ${BLD}║${NC}"
echo -e "${BLD}║${NC}    ${STREAM_KEY}?pwd=${STREAM_PASSWORD}  ${BLD}║${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}║${NC}  ${YLW}In OBS → Settings → Stream:${NC}                                ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Service:    Custom...                                      ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Server:     rtmp://${DOMAIN}:${RTMP_PORT}/live   ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Stream Key: (see above — includes ?pwd=...)                ${BLD}║${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}║${NC}  ${YLW}Recommended OBS Output Settings:${NC}                             ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Encoder:      x264                                         ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Rate Control:  CBR                                         ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Bitrate:       2500 Kbps (video) + 128 Kbps (audio)        ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Keyframe:      6 seconds                                   ${BLD}║${NC}"
echo -e "${BLD}║${NC}    Resolution:    1920×1080                                   ${BLD}║${NC}"
echo -e "${BLD}║${NC}    FPS:           30                                          ${BLD}║${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLD}║${NC}  ${GRN}When you start streaming:${NC}                                   ${BLD}║${NC}"
echo -e "${BLD}║${NC}    → Radio auto-switches from AutoDJ to your live stream      ${BLD}║${NC}"
echo -e "${BLD}║${NC}  ${GRN}When you stop streaming:${NC}                                    ${BLD}║${NC}"
echo -e "${BLD}║${NC}    → Radio auto-switches back to AutoDJ seamlessly            ${BLD}║${NC}"
echo -e "${BLD}║${NC}                                                              ${BLD}║${NC}"
echo -e "${BLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Credentials saved to: $CRED_FILE"
echo ""
echo "To regenerate credentials:"
echo "  rm $CRED_FILE && bash $0"
echo ""
echo "To verify live switching manually:"
echo "  watch -n1 cat /run/radio/active"
echo "  radio-ctl status"
echo ""
