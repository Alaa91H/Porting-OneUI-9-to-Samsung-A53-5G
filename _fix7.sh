#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix6.sh _watch4.sh 2>/dev/null || true
git add -A
git status --short
git commit -m "Try GitHub source + alternatives for samloader installation

samloader was removed from PyPI. Try:
1. PyPI (samloader)
2. GitHub source (git+https://github.com/nlsam/samloader)
3. Alternative packages (samfirm-manifest, samloader-manifest)"
git push origin main
echo "=== Pushed ==="
sleep 35

RUN_ID=$(gh run list \
  --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G \
  --workflow build-port.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')
echo "=== Run $RUN_ID ==="
gh run view "$RUN_ID" --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G 2>&1 | head -30
echo ""
echo "=== Download firmware logs ==="
gh run view "$RUN_ID" --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G --log 2>/dev/null | grep -E 'samloader|FUS|Trying|pip|GitHub|ERROR|WARN' | tail -20
