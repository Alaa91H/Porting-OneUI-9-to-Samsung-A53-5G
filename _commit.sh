#!/usr/bin/env bash
set -e
cd /d/OneUI9Port

# Clean up temp scripts
rm -f _push.sh _trigger.sh _checkrun.sh _debug.sh _pycheck.py 2>/dev/null || true

git add -A
git status --short

git commit -m "Fix build: GitHub API URL resolution, Node 24 actions, dual unrooted+KSU variants

- Fix 00_setup.sh: resolve lpunpack/lpmake/lpdump + magiskboot URLs via
  GitHub API (was hitting 404 on hardcoded release filenames)
- Upgrade GitHub Actions to v5 (checkout/cache/upload-artifact) — fixes
  Node.js 20 deprecation warning
- Fix cache save: only save when downloads/ is non-empty
- Rename 07 output to *_unrooted_* (explicit variant naming)
- Add 08_build_ksu.sh: builds KernelSU rooted variant
  - Strategy A: patch boot.img on CI via ksud (kprobes/SUKI)
  - Strategy B: fall back to bundling KSU manager APK
- Workflow builds both variants, uploads both as artifacts + release
- All script comments migrated to English"

git push origin main
echo "=== Pushed ==="
