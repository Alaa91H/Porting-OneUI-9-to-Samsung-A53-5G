#!/usr/bin/env bash
# ============================================================
# 00_setup.sh — Install all tools required by the porting pipeline
# Targets: Ubuntu 22.04+ / 24.04 / WSL2 / GitHub Actions runners.
# All optional downloads use graceful fallback — one missing source
# does NOT abort the whole setup.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "Installing porting toolchain"

# ----------------------------------------------------------------
# Helper: run a command but never let it kill the script
# ----------------------------------------------------------------
safe_run() {
  "$@" || { log_warn "command failed (non-fatal): $*"; return 1; }
}

# ----------------------------------------------------------------
# 1. System packages via apt
# ----------------------------------------------------------------
log_info "Updating package index and installing core dependencies"
sudo apt-get update -qq
# Install everything we can from apt. Some packages don't exist on
# older Ubuntu releases — we tolerate failures per-package.
for pkg in \
  android-sdk-libsparse \
  android-sdk-platform-tools-common \
  android-tools-fsutils \
  simg2img img2simg \
  e2fsprogs \
  erofs-utils \
  xxd file xz-utils lz4 zstd p7zip-full p7zip-rar \
  wget curl ca-certificates \
  jq python3 python3-pip python3-venv \
  rsync cpio \
  liblp-dev \
  unzip \
  ; do
  sudo apt-get install -y -qq "$pkg" 2>/dev/null || log_debug "apt: $pkg not available (skipped)"
done

# On Ubuntu 24.04 the "android-tools" meta-package ships lpunpack/lpmake/lpdump
sudo apt-get install -y -qq android-tools 2>/dev/null && log_ok "android-tools (lpunpack/lpmake/lpdump) from apt" || true

# ----------------------------------------------------------------
# 2. Dynamic-partition tools: lpunpack / lpmake / lpdump
#    Priority: apt → prebuilt binary (GitHub release) → pip (lpunpack only)
# ----------------------------------------------------------------
install_lp_tools() {
  local dest="/usr/local/bin"

  # Already present?
  local have=0
  command -v lpunpack >/dev/null 2>&1 && have=1
  command -v lpmake  >/dev/null 2>&1 && have=1
  command -v lpdump  >/dev/null 2>&1 && have=1
  if [[ $have -eq 1 ]]; then
    log_ok "lp tools already available"
    return 0
  fi

  local build_dir="$WORK_DIR/aosp-tools"
  mkdir -p "$build_dir"

  # 2a. Resolve the latest prebuilt binary URL via GitHub API
  # Try multiple repos that host lpunpack/lpmake/lpdump prebuilts
  local repos=(
    "LonelyFool/lpunpack_and_lpmake_and_lpdump"
    "unix3dgforce/lptools"
    "erfanoabdi/lptools"
  )
  local dl_urls=""
  for repo in "${repos[@]}"; do
    local api_url="https://api.github.com/repos/${repo}/releases/latest"
    log_info "Trying release: $repo"
    err_off
    dl_urls=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url" \
              | jq -r '.assets[].browser_download_url' 2>/dev/null || true)
    err_on
    if [[ -n "$dl_urls" ]]; then
      log_info "Found assets in $repo"
      break
    fi
  done

  if [[ -n "$dl_urls" ]]; then
    # Pick the first asset (typically a .tar.xz or .zip)
    local asset_url
    asset_url=$(echo "$dl_urls" | head -1)
    log_info "Downloading prebuilt: $asset_url"
    if curl -fsSL "$asset_url" -o "$build_dir/lp_archive"; then
      # Extract based on file type
      if echo "$asset_url" | grep -qiE '\.tar\.xz$'; then
        tar -xJf "$build_dir/lp_archive" -C "$build_dir" 2>/dev/null || true
      elif echo "$asset_url" | grep -qiE '\.tar\.gz$'; then
        tar -xzf "$build_dir/lp_archive" -C "$build_dir" 2>/dev/null || true
      elif echo "$asset_url" | grep -qiE '\.zip$'; then
        unzip -o -q "$build_dir/lp_archive" -d "$build_dir" 2>/dev/null || true
      else
        # Try tar (generic) then unzip
        tar -xf "$build_dir/lp_archive" -C "$build_dir" 2>/dev/null \
          || unzip -o -q "$build_dir/lp_archive" -d "$build_dir" 2>/dev/null || true
      fi
      # Find and install the binaries
      for tool in lpunpack lpmake lpdump; do
        local found
        found=$(find "$build_dir" -type f -name "$tool" -executable 2>/dev/null | head -1 || true)
        if [[ -n "$found" ]]; then
          sudo install -m755 "$found" "$dest/$tool" 2>/dev/null && log_ok "$tool installed from prebuilt"
        fi
      done
    else
      log_warn "Prebuilt download failed"
    fi
  else
    log_warn "Could not resolve lp tools from any GitHub release"
  fi

  # 2b. Fallback: pip-install lpunpack (pure-Python implementation)
  if ! command -v lpunpack >/dev/null 2>&1; then
    log_info "Installing lpunpack via pip (pure Python)"
    err_off
    pip3 install --quiet lpunpack 2>/dev/null \
      || pip3 install --quiet --break-system-packages lpunpack 2>/dev/null \
      || log_warn "pip install lpunpack failed"
    err_on
  fi

  # 2c. Final report
  for tool in lpunpack lpmake lpdump; do
    if command -v "$tool" >/dev/null 2>&1; then
      log_ok "$tool: $(command -v "$tool")"
    else
      log_warn "$tool: NOT installed (needed for super.img operations)"
    fi
  done
}
install_lp_tools

# ----------------------------------------------------------------
# 3. Boot image tools: mkbootimg + magiskboot
# ----------------------------------------------------------------
install_boot_tools() {
  local dest="/usr/local/bin"

  # 3a. mkbootimg (from AOSP googlesource — pure Python)
  if ! command -v mkbootimg >/dev/null 2>&1; then
    log_info "Installing mkbootimg from AOSP"
    local d="$WORK_DIR/mkbootimg"
    err_off
    if git clone --depth=1 https://android.googlesource.com/platform/system/tools/mkbootimg "$d" 2>/dev/null; then
      [[ -f "$d/mkbootimg.py" ]] && sudo install -m755 "$d/mkbootimg.py" "$dest/mkbootimg" 2>/dev/null
    else
      log_warn "git clone mkbootimg failed"
    fi
    err_on
  fi

  # 3b. magiskboot — extract libmagiskboot.so from latest Magisk APK
  if ! command -v magiskboot >/dev/null 2>&1; then
    log_info "Installing magiskboot from latest Magisk release"
    local d="$WORK_DIR/magiskboot"
    mkdir -p "$d"

    # Resolve the actual APK download URL via GitHub API (asset name varies)
    err_off
    local apk_url=""
    apk_url=$(curl -fsSL -H "Accept: application/vnd.github+json" \
              "https://api.github.com/repos/topjohnwu/Magisk/releases/latest" \
              | jq -r '.assets[] | select(.name|test("\\.apk$")) | .browser_download_url' 2>/dev/null | head -1 || true)

    if [[ -n "$apk_url" ]] && curl -fsSL "$apk_url" -o "$d/Magisk.apk" 2>/dev/null; then
      log_info "Extracting libmagiskboot.so from APK"
      if python3 - "$d/Magisk.apk" "$d" <<'PY'
import zipfile, os, sys
apk, out = sys.argv[1], sys.argv[2]
try:
    z = zipfile.ZipFile(apk)
except Exception as e:
    print(f"ERROR: cannot open apk: {e}", file=sys.stderr)
    sys.exit(1)
for n in z.namelist():
    if 'libmagiskboot' in n and 'x86_64' in n:
        z.extract(n, out)
        print(f"extracted: {n}", file=sys.stderr)
        break
else:
    print("ERROR: libmagiskboot.so (x86_64) not found in apk", file=sys.stderr)
    sys.exit(1)
PY
      then
        local lib
        lib=$(ls "$d"/lib/x86_64/libmagiskboot.so 2>/dev/null || true)
        if [[ -n "$lib" ]]; then
          sudo install -m755 "$lib" "$dest/magiskboot" 2>/dev/null && log_ok "magiskboot installed"
        else
          log_warn "libmagiskboot.so not found after extraction"
        fi
      else
        log_warn "Failed to extract magiskboot from APK"
      fi
    else
      log_warn "Could not download Magisk APK (URL: ${apk_url:-<none>})"
    fi
    err_on
  fi
}
install_boot_tools

# ----------------------------------------------------------------
# 4. Python dependencies (firmware fetcher + APK processing)
# ----------------------------------------------------------------
log_info "Installing Python dependencies (cloudscraper, requests)"
err_off
PIP_FLAGS=""
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)" 2>/dev/null \
  && PIP_FLAGS="--break-system-packages" || PIP_FLAGS=""
pip3 install --quiet $PIP_FLAGS cloudscraper requests 2>/dev/null \
  || pip3 install --quiet cloudscraper requests 2>/dev/null \
  || pip3 install --quiet --user cloudscraper requests 2>/dev/null \
  || log_warn "pip install cloudscraper/requests failed — firmware fetcher may not work"
err_on

# ----------------------------------------------------------------
# 5. Final verification report
# ----------------------------------------------------------------
log_step "Verifying installed tools"
critical=(simg2img img2simg mkfs.erofs dump.erofs file xxd jq rsync curl unzip)
optional=(lpunpack lpmake lpdump mkbootimg magiskboot)
missing_critical=0

for t in "${critical[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    log_ok "$t"
  else
    log_error "missing critical: $t"
    missing_critical=1
  fi
done
for t in "${optional[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then
    log_ok "$t"
  else
    log_warn "missing optional: $t (may need manual build)"
  fi
done

log_step "Verifying Python firmware fetcher"
if python3 -c "import requests, cloudscraper" 2>/dev/null; then
  log_ok "Python firmware fetcher ready"
else
  log_warn "cloudscraper/requests not importable — run: pip install cloudscraper requests"
fi

if [[ "$missing_critical" -ne 0 ]]; then
  die "One or more CRITICAL tools are missing. Fix the above errors before continuing."
fi

log_ok "Setup complete. Next: bash scripts/01_download_firmware.sh"
