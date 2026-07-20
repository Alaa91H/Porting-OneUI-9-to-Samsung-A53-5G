#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _monitor.sh _commit.sh _push.sh _trigger.sh _checkrun.sh _debug.sh _pycheck.py 2>/dev/null || true
git add -A
git status --short
git commit -m "Fix ERR trap killing scripts on tolerated failures

- Add err_off/err_on helpers to common.sh to suppress the ERR trap
  around commands that do their own error handling (|| / return)
- Wrap all network calls in 00_setup.sh (curl/git/pip) with err_off/err_on
- Wrap env loading in 01_download_firmware.sh with err_off/err_on
- load_env() now returns 1 instead of dying on missing config files
- Try multiple GitHub repos for lpunpack/lpmake/lpdump prebuilts"
git push origin main
echo "=== Pushed ==="
