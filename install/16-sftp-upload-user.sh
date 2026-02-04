#!/usr/bin/env bash
###############################################################################
# CREATE SFTP UPLOAD USER
# People We Like Radio Installation - Step 16
#
# Creates a jailed SFTP-only user that can write to /srv/radio/content.
# Generates a random password at install time and prints it ONCE.
###############################################################################
set -euo pipefail

UPLOAD_USER="${UPLOAD_USER:-radio_upload}"
UPLOAD_GROUP="${UPLOAD_GROUP:-radio_upload}"
CONTENT_DIR="/srv/radio/content"
CHROOT_DIR="/srv/radio"

echo "=============================================="
echo "  SFTP Upload User Setup"
echo "=============================================="

# ── 1. Create directory structure ──
echo "[1/5] Creating content directories..."

DAYS="monday tuesday wednesday thursday friday saturday sunday"
PARTS="morning day evening night"

mkdir -p "$CONTENT_DIR/_fallback"

for d in $DAYS; do
    for p in $PARTS; do
        mkdir -p "$CONTENT_DIR/$d/$p"
    done
done

echo "    Created 7 days x 4 dayparts + _fallback"

# ── 2. Create group + user ──
echo "[2/5] Creating SFTP user..."

if ! getent group "$UPLOAD_GROUP" &>/dev/null; then
    groupadd "$UPLOAD_GROUP"
    echo "    Created group: $UPLOAD_GROUP"
else
    echo "    Group already exists: $UPLOAD_GROUP"
fi

if ! id "$UPLOAD_USER" &>/dev/null; then
    useradd -g "$UPLOAD_GROUP" -d /content -s /usr/sbin/nologin "$UPLOAD_USER"
    echo "    Created user: $UPLOAD_USER"
else
    echo "    User already exists: $UPLOAD_USER"
fi

# Generate random password
PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
echo "$UPLOAD_USER:$PASS" | chpasswd

# ── 3. Set ownership for chroot ──
# ChrootDirectory must be owned by root:root and not group/world writable
echo "[3/5] Setting chroot ownership..."

chown root:root "$CHROOT_DIR"
chmod 755 "$CHROOT_DIR"

# Content dir must be writable by the upload user
chown root:"$UPLOAD_GROUP" "$CONTENT_DIR"
chmod 775 "$CONTENT_DIR"

for d in $DAYS; do
    chown root:"$UPLOAD_GROUP" "$CONTENT_DIR/$d"
    chmod 775 "$CONTENT_DIR/$d"
    for p in $PARTS; do
        chown "$UPLOAD_USER":"$UPLOAD_GROUP" "$CONTENT_DIR/$d/$p"
        chmod 775 "$CONTENT_DIR/$d/$p"
    done
done

chown "$UPLOAD_USER":"$UPLOAD_GROUP" "$CONTENT_DIR/_fallback"
chmod 775 "$CONTENT_DIR/_fallback"

# Liquidsoap user needs read access
usermod -aG "$UPLOAD_GROUP" liquidsoap 2>/dev/null || true

# ── 4. Configure SSHD for SFTP jail ──
echo "[4/5] Configuring SSHD..."

SSHD_CONFIG="/etc/ssh/sshd_config"

# Remove existing Match block for this user if present
if grep -q "^Match User $UPLOAD_USER" "$SSHD_CONFIG"; then
    # Remove old block (Match User ... up to next Match or end)
    sed -i "/^Match User $UPLOAD_USER/,/^\(Match\|^$\)/{/^Match User $UPLOAD_USER/d;/^[[:space:]]/d}" "$SSHD_CONFIG"
    echo "    Removed existing SFTP config block"
fi

# Append new Match block
cat >> "$SSHD_CONFIG" <<SSHEOF

Match User $UPLOAD_USER
    ForceCommand internal-sftp -d /content
    ChrootDirectory $CHROOT_DIR
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
SSHEOF

echo "    Added SFTP jail config to sshd_config"

# Test sshd config before restarting
if sshd -t 2>/dev/null; then
    systemctl restart sshd
    echo "    SSHD restarted successfully"
else
    echo "ERROR: sshd config test failed. Check $SSHD_CONFIG"
    exit 1
fi

# ── 5. Set default umask for uploads ──
echo "[5/5] Configuring upload permissions..."

# PAM umask ensures new files are group-readable (for Liquidsoap)
if ! grep -q "^session.*pam_umask.*002" /etc/pam.d/sshd 2>/dev/null; then
    echo "session optional pam_umask.so umask=002" >> /etc/pam.d/sshd
    echo "    Set umask 002 for SFTP uploads"
fi

echo ""
echo "=============================================="
echo "  SFTP Upload User Ready"
echo "=============================================="
echo ""
echo "  Host:      $(hostname -f 2>/dev/null || hostname)"
echo "  Username:  $UPLOAD_USER"
echo "  Password:  $PASS"
echo "  Port:      22"
echo "  Path:      /content/"
echo ""
echo "  Example SFTP command:"
echo "    sftp $UPLOAD_USER@$(hostname -f 2>/dev/null || hostname)"
echo "    > cd /content/monday/morning"
echo "    > put track.mp3"
echo ""
echo "  Directory layout:"
echo "    /content/"
echo "      monday/   (morning, day, evening, night)"
echo "      tuesday/  (morning, day, evening, night)"
echo "      ...       "
echo "      sunday/   (morning, day, evening, night)"
echo "      _fallback/"
echo ""
echo "  SAVE THE PASSWORD ABOVE — it will not be shown again."
echo ""
