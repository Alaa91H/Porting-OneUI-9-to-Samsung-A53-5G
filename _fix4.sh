#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix3.sh _watch3.sh _watch2.sh 2>/dev/null || true
git add -A
git status --short
git commit -m "Fix err->log_error and target region XEU->EUX

- Fix 'err: command not found' (should be log_error) in 01_download
- Fix target.env: DEVICE_MODEL_REGION was XEU, should be EUX (per
  samfw.com/firmware/SM-A536B/EUX)"
git push origin main
echo "=== Pushed ==="
