#!/usr/bin/env bash
cd /d/OneUI9Port
echo "=== Bash ==="
fail=0
for f in scripts/*.sh scripts/lib/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>err.tmp; then echo "OK    $f"; else echo "FAIL  $f"; cat err.tmp; fail=1; fi
done
rm -f err.tmp

echo "=== Python ==="
PYBIN=""
for c in python3 python; do "$c" --version >/dev/null 2>&1 && PYBIN="$c" && break; done
if [ -n "$PYBIN" ]; then
  for f in scripts/firmware/*.py; do
    [ -f "$f" ] || continue
    "$PYBIN" -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "$f" 2>/dev/null \
      && echo "OK    $f" || { echo "FAIL  $f"; fail=1; }
  done
  echo "=== YAML/JSON ==="
  "$PYBIN" - <<'PYEOF'
import glob, sys
try:
    import yaml
except: yaml = None
import json
ok = True
for f in glob.glob(".github/workflows/*.yml"):
    try:
        if yaml: yaml.safe_load(open(f, encoding="utf-8"))
        print(f"OK    {f}")
    except Exception as e: print(f"FAIL  {f}: {e}"); ok=False
for f in glob.glob("config/*.json"):
    try:
        json.loads(open(f, encoding="utf-8").read())
        print(f"OK    {f}")
    except Exception as e: print(f"FAIL  {f}: {e}"); ok=False
sys.exit(0 if ok else 1)
PYEOF
  [ $? -ne 0 ] && fail=1
fi

echo "==="
[ "$fail" = "0" ] && echo "ALL PASSED" || echo "HAS FAILURES"
exit $fail
