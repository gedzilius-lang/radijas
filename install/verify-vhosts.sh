#!/bin/bash
set -e
FAIL=0

echo "=== Vhost Verification ==="

# HTTP radio
R80=$(curl -s http://127.0.0.1/ -H 'Host: radio.peoplewelike.club' 2>&1 | head -100)
if echo "$R80" | grep -qi "people we like\|radio"; then
  echo "[PASS] HTTP radio -> radio content"
else
  echo "[FAIL] HTTP radio -> wrong content"
  FAIL=1
fi

# HTTP av (should return nothing/444)
A80=$(curl -sI http://127.0.0.1/ -H 'Host: av.peoplewelike.club' 2>&1)
if [ -z "$A80" ] || echo "$A80" | grep -q "444"; then
  echo "[PASS] HTTP av -> 444/empty (no av vhost)"
else
  echo "[FAIL] HTTP av -> unexpected response"
  FAIL=1
fi

# HTTPS radio
R443=$(curl -sk https://127.0.0.1/ -H 'Host: radio.peoplewelike.club' 2>&1 | head -100)
if echo "$R443" | grep -qi "people we like\|radio"; then
  echo "[PASS] HTTPS radio -> radio content"
else
  echo "[FAIL] HTTPS radio -> wrong content"
  FAIL=1
fi

# HTTPS av (should return nothing/444)
A443=$(curl -skI https://127.0.0.1/ -H 'Host: av.peoplewelike.club' 2>&1)
if [ -z "$A443" ] || echo "$A443" | grep -q "444"; then
  echo "[PASS] HTTPS av -> 444/empty (no av vhost)"
else
  echo "[FAIL] HTTPS av -> unexpected response"
  FAIL=1
fi

# Check for av content in radio responses
if echo "$R80$R443" | grep -qi "illuminatics\|av\.peoplewelike"; then
  echo "[FAIL] Radio serving av content!"
  FAIL=1
fi

if [ $FAIL -eq 0 ]; then
  echo "=== ALL PASS ==="
  exit 0
else
  echo "=== VERIFICATION FAILED ==="
  exit 1
fi
