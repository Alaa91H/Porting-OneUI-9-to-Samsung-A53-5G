#!/usr/bin/env bash
# ============================================================
# 01_download_firmware.sh — Resolve & download both firmware packages
#
# Resolution order (per device):
#   1. Direct URL from environment / GitHub Secret (highest priority)
#   2. samfw.com listing (latest, or specific PDA via env)
#   3. GitHub Releases asset fallback (manual upload)
#
# The actual fetching logic lives in scripts/firmware/samfw_fetcher.py, which
# handles Cloudflare bypass, the samfw countdown, resume, and SHA1 verification.
# This shell wrapper selects model/region/PDA from config and invokes it.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "Resolve & download firmware packages"
ensure_dirs
load_source_env 2>/dev/null || true
load_target_env 2>/dev/null || true

FETCHER="$SCRIPT_DIR/firmware/samfw_fetcher.py"
[[ -f "$FETCHER" ]] || die "Firmware fetcher not found: $FETCHER"
command -v python3 >/dev/null 2>&1 || die "python3 is required (run 00_setup.sh)"

# GitHub repo slug for the Releases fallback (auto-detected in CI)
GITHUB_REPO="${GITHUB_REPOSITORY:-Alaa91H/Porting-OneUI-9-to-Samsung-A53-5G}"

# ----------------------------------------------------------------
# run_fetcher <label> <model> <region> [pda]
# ----------------------------------------------------------------
run_fetcher() {
  local label="$1" model="$2" region="$3" pda="${4:-}"
  local args=(fetch --model "$model" --region "$region" --out "$DOWNLOAD_DIR"
              --github-repo "$GITHUB_REPO")
  [[ -n "$pda" ]] && args+=(--pda "$pda")
  log_info "[$label] Resolving firmware for $model / $region ${pda:+(PDA $pda)}"
  if python3 "$FETCHER" "${args[@]}"; then
    log_ok "[$label] firmware downloaded"
    return 0
  fi
  log_warn "[$label] automatic resolution failed"
  return 1
}

# ----------------------------------------------------------------
# Override handling: if a direct URL is provided (env or secret),
# pass it through to the fetcher so it skips samfw entirely.
# ----------------------------------------------------------------
# Source (S26 Ultra) — default region XEU (Europe, unbranded)
SRC_MODEL="${DEVICE_MODEL:-SM-S948B}"
# DEVICE_MODEL in source.env is SM-S948B; fall back if unset
[[ "$SRC_MODEL" == "SM-S948B" ]] || SRC_MODEL="SM-S948B"
SRC_REGION="${DEVICE_MODEL_REGION:-XEU}"
SRC_PDA="${SOURCE_PDA:-}"

# Target (A53 5G) — default region EUX
TGT_MODEL="${DEVICE_MODEL:-SM-A536B}"
[[ "$TGT_MODEL" == "SM-A536B" ]] || TGT_MODEL="SM-A536B"
# target.env may override DEVICE_MODEL; reload explicitly for safety
if [[ -n "${TARGET_DEVICE_MODEL:-}" ]]; then TGT_MODEL="$TARGET_DEVICE_MODEL"; fi
TGT_REGION="${DEVICE_MODEL_REGION:-EUX}"
# target.env sets DEVICE_MODEL_REGION; ensure we read the target one
load_env "$CONFIG_DIR/target.env" TARGET_ 2>/dev/null || true
TGT_MODEL="${TARGET_DEVICE_MODEL:-$TGT_MODEL}"
TGT_REGION="${TARGET_DEVICE_MODEL_REGION:-$TGT_REGION}"
TGT_PDA="${TARGET_PDA:-}"

log_info "Source device: $SRC_MODEL / $SRC_REGION"
log_info "Target device: $TGT_MODEL / $TGT_REGION"

# ----------------------------------------------------------------
# 1. Source firmware (S26 Ultra)
# ----------------------------------------------------------------
log_step "1/2 — Source firmware (Samsung Galaxy S26 Ultra)"
src_ok=0
if [[ -n "${SOURCE_FIRMWARE_URL:-}" ]]; then
  log_info "Using direct URL override for source"
  python3 "$FETCHER" fetch --model "$SRC_MODEL" --region "$SRC_REGION" \
    --out "$DOWNLOAD_DIR" --direct-url "$SOURCE_FIRMWARE_URL" \
    --github-repo "$GITHUB_REPO" && src_ok=1 || src_ok=0
fi
if [[ "$src_ok" -eq 0 ]]; then
  run_fetcher "source" "$SRC_MODEL" "$SRC_REGION" "$SRC_PDA" || src_ok=0
  # Re-check: if a local file exists we treat it as success
  [[ -z "$(find "$DOWNLOAD_DIR" -maxdepth 1 -iname "*S948B*.tar.md5" -print -quit 2>/dev/null)" ]] \
    || src_ok=1
fi

# ----------------------------------------------------------------
# 2. Target firmware (A53 5G)
# ----------------------------------------------------------------
log_step "2/2 — Target firmware (Samsung Galaxy A53 5G)"
tgt_ok=0
if [[ -n "${TARGET_FIRMWARE_URL:-}" ]]; then
  log_info "Using direct URL override for target"
  python3 "$FETCHER" fetch --model "$TGT_MODEL" --region "$TGT_REGION" \
    --out "$DOWNLOAD_DIR" --direct-url "$TARGET_FIRMWARE_URL" \
    --github-repo "$GITHUB_REPO" && tgt_ok=1 || tgt_ok=0
fi
if [[ "$tgt_ok" -eq 0 ]]; then
  run_fetcher "target" "$TGT_MODEL" "$TGT_REGION" "$TGT_PDA" || tgt_ok=0
  [[ -z "$(find "$DOWNLOAD_DIR" -maxdepth 1 -iname "*A536B*.tar.md5" -print -quit 2>/dev/null)" ]] \
    || tgt_ok=1
fi

# ----------------------------------------------------------------
# 3. Locate the downloaded files and verify
# ----------------------------------------------------------------
log_step "Locating downloaded packages"
SOURCE_FIRMWARE="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \
  \( -iname "*S948B*.tar.md5" -o -iname "source_*.tar.md5" -o -iname "*SM-S948B*" \) \
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')"
SOURCE_FIRMWARE="${SOURCE_FIRMWARE:-}"
TARGET_FIRMWARE="$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \
  \( -iname "*A536B*.tar.md5" -o -iname "target_*.tar.md5" -o -iname "*SM-A536B*" \) \
  -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')"
TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"

if [[ -z "$SOURCE_FIRMWARE" || -z "$TARGET_FIRMWARE" ]]; then
  err "Could not locate both firmware packages."
  cat <<HINT

  Missing:
$([[ -z "$SOURCE_FIRMWARE" ]] && echo "    - SOURCE: S26 Ultra firmware (SM-S948B)")
$([[ -z "$TARGET_FIRMWARE" ]] && echo "    - TARGET: A53 5G firmware (SM-A536B)")

  Manual recovery options:
    1. Download manually from https://samfw.com/firmware/SM-S948B/XEU
       and https://samfw.com/firmware/SM-A536B/EUX, then place the
       .tar.md5 files in: $DOWNLOAD_DIR/
    2. Or upload them as release assets to:
       https://github.com/$GITHUB_REPO/releases
       (name them SM-S948B_*.tar.md5 / SM-A536B_*.tar.md5)
    3. Or set GitHub Secrets:
       SOURCE_FIRMWARE_URL, TARGET_FIRMWARE_URL  (direct .tar.md5 URLs)
HINT
  exit 2
fi

log_ok "Source: $SOURCE_FIRMWARE ($(numfmt --to=iec "$(stat -c%s "$SOURCE_FIRMWARE")" 2>/dev/null || echo '?'))"
log_ok "Target: $TARGET_FIRMWARE ($(numfmt --to=iec "$(stat -c%s "$TARGET_FIRMWARE")" 2>/dev/null || echo '?'))"

# ----------------------------------------------------------------
# 4. Samsung .tar.md5 integrity check (trailing MD5 signature)
# ----------------------------------------------------------------
verify_samsung_md5() {
  local f="$1" name="$2"
  log_info "Verifying Samsung MD5 trailer: $name"
  # Samsung .tar.md5 files embed a 32-hex MD5 line near the end (padded to 4K)
  local trailer; trailer="$(tail -c 8192 "$f" | grep -aoE '^[0-9a-f]{32}' | head -1 || true)"
  if [[ -n "$trailer" ]]; then
    # Recompute MD5 of the whole file and compare
    local actual; actual="$(md5sum "$f" | awk '{print $1}')"
    if [[ "${actual,,}" == "${trailer,,}" ]]; then
      ok "$name: MD5 OK ($trailer)"
    else
      log_warn "$name: MD5 mismatch (trailer=$trailer actual=$actual) — file may be corrupt"
    fi
  else
    log_debug "$name: no Samsung MD5 trailer (acceptable for some regions)"
  fi
}
verify_samsung_md5 "$SOURCE_FIRMWARE" "source"
verify_samsung_md5 "$TARGET_FIRMWARE" "target"

# ----------------------------------------------------------------
# 5. Persist paths for downstream scripts
# ----------------------------------------------------------------
cat > "$WORK_DIR/firmware_paths.env" <<EOF
SOURCE_FIRMWARE="$SOURCE_FIRMWARE"
TARGET_FIRMWARE="$TARGET_FIRMWARE"
SOURCE_MODEL="$SRC_MODEL"
SOURCE_REGION="$SRC_REGION"
TARGET_MODEL="$TGT_MODEL"
TARGET_REGION="$TGT_REGION"
EOF
ok "Paths persisted to $WORK_DIR/firmware_paths.env"
log_step "Next: bash scripts/02_extract_firmware.sh"
