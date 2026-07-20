#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix.sh _watch.sh _monitor.sh _commit.sh _push.sh _trigger.sh _checkrun.sh _debug.sh _pycheck.py 2>/dev/null || true
git add -A
git status --short
git commit -m "Fix PROJECT_ROOT path (was scripts/lib/ instead of repo root)

common.sh: SCRIPT_DIR pointed to scripts/lib/ (where common.sh lives),
causing FETCHER path to resolve to scripts/lib/firmware/ (non-existent).
- Add LIB_DIR for scripts/lib/ explicitly
- Fix PROJECT_ROOT to go up two levels from lib/
- Fix FETCHER path in 01 to use PROJECT_ROOT/scripts/firmware/"
git push origin main
echo "=== Pushed ==="
