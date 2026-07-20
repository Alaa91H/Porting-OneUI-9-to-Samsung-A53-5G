#!/usr/bin/env bash
set -e
cd /d/OneUI9Port
rm -f _fix5.sh 2>/dev/null || true
git rm -r --cached .playwright-mcp/ 2>/dev/null || true
git add -A
git status --short
git commit -m "Remove Playwright snapshots from tracking; add to .gitignore"
git push origin main
echo "=== Pushed ==="

# Wait for build
sleep 30
echo ""
echo "=== Latest runs ==="
gh run list \
  --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G \
  --workflow build-port.yml \
  --limit 1

RUN_ID=$(gh run list \
  --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G \
  --workflow build-port.yml \
  --limit 1 \
  --json databaseId \
  --jq '.[0].databaseId')
echo ""
echo "=== Run $RUN_ID status ==="
gh run view "$RUN_ID" --repo Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G 2>&1 | head -30
