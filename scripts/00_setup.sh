#!/usr/bin/env bash
# ============================================================
# 00_setup.sh — تثبيت كل الأدوات اللازمة لعملية البورت
# يعمل على Ubuntu 20.04+ وWSL2 وGitHub Actions (ubuntu-latest).
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "تثبيت أدوات البورت"

# --- 1. حزم النظام ---
log_info "تحديث فهرس الحزم وتثبيت الاعتماديات الأساسية"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  android-sdk-libsparse android-sdk-platform-tools-common \
  simg2img img2simg \
  e2fsprogs e2fsprogs-ng \
  erofs-utils \
  xxd file xz-utils lz4 zstd p7zip-full p7zip-rar \
  wget curl ca-certificates \
  jq python3 python3-pip \
  rsync cpio \
  liblp-dev 2>/dev/null || true

# --- 2. أدوات الأقسام الديناميكية (lpunpack/lpmake/lpdump) ---
# غير متوفرة دائماً في apt، نبنيها من AOSP tools.
install_lp_tools() {
  local dest="/usr/local/bin"
  if command -v lpunpack >/dev/null 2>&1 && command -v lpmake >/dev/null 2>&1; then
    log_ok "أدوات liblp (lpunpack/lpmake/lpdump) متوفرة"
    return 0
  fi
  log_info "بناء أدوات الأقسام الديناميكية من AOSP"
  local build_dir="$WORK_DIR/aosp-tools"
  mkdir -p "$build_dir"

  # نسخة ثابتة من android-tools (تحتوي liblp)
  if [[ ! -d "$build_dir/android-tools" ]]; then
    git clone --depth=1 https://github.com/nickcano/android-tools-mirror.git "$build_dir/android-tools" 2>/dev/null \
      || git clone --depth=1 https://github.com/nickcano/AOSP-mirror.git "$build_dir/android-tools" 2>/dev/null \
      || true
  fi

  # بديل: ثنائيات مجمّعة من releases
  local bin_url="https://github.com/LonelyFool/lpunpack_and_lpmake_and_lpdump/releases/latest/download/lpunpack_and_lpmake_and_lpdump.tar.xz"
  log_info "تنزيل ثنائيات lpunpack/lpmake/lpdump الجاهزة"
  if curl -fsSL "$bin_url" -o "$build_dir/lp.tar.xz"; then
    tar -xf "$build_dir/lp.tar.xz" -C "$build_dir"
    sudo install -m755 "$build_dir"/lpunpack "$dest"/lpunpack 2>/dev/null || true
    sudo install -m755 "$build_dir"/lpmake "$dest"/lpmake 2>/dev/null || true
    sudo install -m755 "$build_dir"/lpdump "$dest"/lpdump 2>/dev/null || true
  else
    log_warn "تعذّر تنزيل ثنائيات liblp — راجع README لبنائها يدوياً."
  fi
}
install_lp_tools

# --- 3. mkbootimg و unpackbootimg ---
install_boot_tools() {
  local dest="/usr/local/bin"
  if ! command -v mkbootimg >/dev/null 2>&1; then
    log_info "تنزيل mkbootimg"
    local d="$WORK_DIR/mkbootimg"
    git clone --depth=1 https://android.googlesource.com/platform/system/tools/mkbootimg "$d" 2>/dev/null || true
    [[ -f "$d/mkbootimg.py" ]] && sudo install -m755 "$d/mkbootimg.py" "$dest/mkbootimg"
  fi
  if ! command -v unpackbootimg >/dev/null 2>&1; then
    log_info "تنزيل magiskboot (لباتش boot.img)"
    local d="$WORK_DIR/magiskboot"
    mkdir -p "$d"
    local url="https://github.com/topjohnwu/Magisk/releases/latest/download/Magisk.apk"
    curl -fsSL "$url" -o "$d/Magisk.apk"
    # magiskboot مدمج داخل الـ apk كأصل lib/x86_64/libmagiskboot.so
    python3 - "$d/Magisk.apk" "$d" <<'PY'
import zipfile, os, sys
apk, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(apk)
for n in z.namelist():
    if 'libmagiskboot' in n and 'x86_64' in n:
        z.extract(n, out)
        break
PY
    local lib; lib="$(ls "$d"/lib/x86_64/libmagiskboot.so 2>/dev/null || true)"
    [[ -n "$lib" ]] && sudo install -m755 "$lib" "$dest/magiskboot"
  fi
}
install_boot_tools

# --- 4. Python dependencies for firmware fetcher & APK processing ---
log_info "Installing Python dependencies"
# cloudscraper: bypasses Cloudflare challenge on samfw.com / samfreaks.com
# requests: HTTP client for the firmware fetcher
PIP_BREAK="--break-system-packages"
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)" 2>/dev/null \
  || PIP_BREAK=""  # older systems don't need the flag
pip3 install --quiet $PIP_BREAK cloudscraper requests 2>/dev/null \
  || pip3 install --quiet cloudscraper requests 2>/dev/null \
  || { log_warn "pip install failed — firmware fetcher will need manual install of cloudscraper"; }

# --- 5. Final verification ---
log_step "Verifying installed tools"
tools=(simg2img img2simg mkfs.erofs dump.erofs file xxd jq rsync wget curl)
for t in "${tools[@]}"; do
  if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_warn "missing: $t"; fi
done
for t in lpunpack lpmake lpdump mkbootimg magiskboot; do
  if command -v "$t" >/dev/null 2>&1; then log_ok "$t"; else log_warn "missing: $t (may need manual build)"; fi
done

# Verify Python firmware-fetcher dependencies
log_step "Verifying Python firmware fetcher dependencies"
if python3 -c "import requests, cloudscraper" 2>/dev/null; then
  log_ok "Python firmware fetcher ready"
else
  log_warn "cloudscraper/requests not importable — run: pip install cloudscraper requests"
fi

log_ok "Setup complete. Next: bash scripts/01_download_firmware.sh"
