#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix2.sh _watch2.sh _watch.sh _monitor.sh _fix.sh 2>/dev/null || true
git add -A
git status --short
git commit -m "Fix firmware download: prefixed env loading, ok->log_ok, find .tar.md5 only

- Load source.env/target.env with SRC_/TGT_ prefixes so they don't
  overwrite each other's DEVICE_MODEL_REGION (was causing target to
  use XEU instead of EUX)
- Fix 'ok' command not found (should be log_ok) on lines 161 + 183
- Fix find patterns to only match *.tar.md5 files (was matching .json
  sidecar files like SM-S948B_fetch.json as 'firmware')
- Wrap python3 fetcher calls with err_off/err_on to tolerate failures"
git push origin main
echo "=== Pushed ==="
