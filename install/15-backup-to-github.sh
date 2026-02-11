#!/usr/bin/env bash
###############################################################################
# BACKUP TO GITHUB
# People We Like Radio — Push all project files to a GitHub repository.
#
# Usage:
#   GITHUB_REPO=git@github.com:youruser/radijas.git bash install/15-backup-to-github.sh
#
# Or edit GITHUB_REPO below before running.
###############################################################################
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-}"
BRANCH="${BRANCH:-main}"
RADIO_DIR="${RADIO_DIR:-/root/radijas}"

echo "=============================================="
echo "  Backup to GitHub"
echo "=============================================="

# ── 1. Verify git ──
if ! command -v git &>/dev/null; then
    echo "ERROR: git is not installed. Run: apt-get install -y git"
    exit 1
fi
echo "[1/5] git found: $(git --version)"

# ── 2. Check repo directory ──
if [ ! -d "$RADIO_DIR" ]; then
    echo "ERROR: Directory $RADIO_DIR does not exist."
    exit 1
fi
cd "$RADIO_DIR"
echo "[2/5] Working directory: $RADIO_DIR"

# ── 3. Initialize repo if needed ──
if [ ! -d ".git" ]; then
    echo "[3/5] Initializing git repository..."
    git init
    git checkout -b "$BRANCH"
else
    echo "[3/5] Git repository already initialized"
fi

# ── 4. Set remote ──
if [ -z "$GITHUB_REPO" ]; then
    echo ""
    echo "ERROR: GITHUB_REPO is not set."
    echo ""
    echo "Usage:"
    echo "  GITHUB_REPO=git@github.com:youruser/radijas.git bash $0"
    echo ""
    echo "Or with HTTPS:"
    echo "  GITHUB_REPO=https://github.com/youruser/radijas.git bash $0"
    exit 1
fi

if git remote get-url origin &>/dev/null; then
    CURRENT_REMOTE=$(git remote get-url origin)
    if [ "$CURRENT_REMOTE" != "$GITHUB_REPO" ]; then
        echo "[4/5] Updating remote origin to $GITHUB_REPO"
        git remote set-url origin "$GITHUB_REPO"
    else
        echo "[4/5] Remote origin already set to $GITHUB_REPO"
    fi
else
    echo "[4/5] Adding remote origin: $GITHUB_REPO"
    git remote add origin "$GITHUB_REPO"
fi

# ── 5. Commit and push ──
echo "[5/5] Staging and pushing..."

# Stage all tracked and new files (respects .gitignore)
git add -A

# Only commit if there are changes
if git diff --cached --quiet; then
    echo "    No new changes to commit"
else
    git commit -m "Backup: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "    Changes committed"
fi

# Push
git push -u origin "$BRANCH"
echo "    Pushed to $GITHUB_REPO ($BRANCH)"

echo ""
echo "=============================================="
echo "  Backup Complete"
echo "=============================================="
echo ""
echo "Repository: $GITHUB_REPO"
echo "Branch:     $BRANCH"
echo ""
