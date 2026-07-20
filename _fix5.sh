#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix4.sh _watch4.sh _pycheck.py _watch3.sh 2>/dev/null || true
git add -A
git status --short
git commit -m "Add Samsung FUS direct download (bypasses Cloudflare entirely)

samfw.com blocks CI runners with Cloudflare 403. Add two new firmware
sources that download directly from Samsung's official FUS server:
1. samloader (Python package) — implements FUS protocol
2. Custom FUS protocol implementation — fallback if samloader fails

Resolution order is now:
  1. Direct URL override (env/secret)
  2. Samsung FUS via samloader
  3. Samsung FUS direct protocol
  4. samfw.com (Cloudflare-protected, often fails on CI)
  5. GitHub Releases fallback"
git push origin main
echo "=== Pushed ==="
