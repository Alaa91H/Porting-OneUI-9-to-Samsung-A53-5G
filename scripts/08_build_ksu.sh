#!/usr/bin/env bash
# ============================================================
# 08_build_ksu.sh — Build the KernelSU (rooted) variant
#
# Produces a KSU-rooted version of the ROM by patching boot.img with
# KernelSU. Two strategies are attempted:
#
#   Strategy A: Patch boot.img on CI using ksud (Linux x86_64)
#     1. Download the latest KernelSU manager APK
#     2. Extract libksud.so (x86_64) and run: ksud boot-patch
#     3. If successful → single integrated KSU zip with patched boot
#
#   Strategy B: Fall back to bundling the KernelSU manager APK
#     If on-CI patching fails (common — Samsung kernels often lack
#     kprobes), produce:
#       - The unrooted ROM zip (copied from step 07)
#       - KernelSU_manager.apk (user installs + patches on-device)
#
# Output:
#   output/OneUI9_a53x_Port_KSU_<tag>.zip   (integrated, if patching works)
#   output/OneUI9_a53x_Port_KSU_<tag>.apk   (KSU manager, always)
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "Building KernelSU (rooted) variant"
require_tools zip unzip curl
load_target_env

REPACK_DIR="$WORK_DIR/repacked"
KSU_WORK="$WORK_DIR/ksu_build"
KSU_APK_DIR="$WORK_DIR/ksu_apk"
mkdir -p "$KSU_WORK" "$KSU_APK_DIR"

VERSION_TAG="$(git_info | tr ' ' '_')"
VARIANT="KSU"
KSU_ZIP_NAME="OneUI9_${DEVICE_CODENAME}_Port_${VARIANT}_${VERSION_TAG}.zip"
KSU_ZIP_OUT="$OUTPUT_DIR/$KSU_ZIP_NAME"
KSU_APK_NAME="KernelSU_manager_${VERSION_TAG}.apk"
KSU_APK_OUT="$OUTPUT_DIR/$KSU_APK_NAME"

# ----------------------------------------------------------------
# 1. Download the latest KernelSU manager APK
# ----------------------------------------------------------------
log_step "1/4 — Downloading KernelSU manager"
KSU_API="https://api.github.com/repos/tiann/KernelSU/releases/latest"
KSU_APK_URL=""
KSU_APK_URL=$(curl -fsSL -H "Accept: application/vnd.github+json" "$KSU_API" \
  | jq -r '.assets[] | select(.name | test("\\.apk$")) | .browser_download_url' 2>/dev/null | head -1 || true)

if [[ -z "$KSU_APK_URL" ]]; then
  # Fallback: try KernelSU-Next fork
  log_warn "KernelSU official release had no APK; trying KernelSU-Next"
  KSU_APK_URL=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/KernelSU-Next/KernelSU-Next/releases/latest" \
    | jq -r '.assets[] | select(.name | test("\\.apk$")) | .browser_download_url' 2>/dev/null | head -1 || true)
fi

if [[ -z "$KSU_APK_URL" ]]; then
  die "Could not resolve KernelSU manager APK URL from GitHub API"
fi

log_info "Downloading: $KSU_APK_URL"
if ! curl -fsSL "$KSU_APK_URL" -o "$KSU_APK_DIR/KernelSU.apk"; then
  die "Failed to download KernelSU manager APK"
fi
log_ok "Downloaded KernelSU manager APK ($(numfmt --to=iec "$(stat -c%s "$KSU_APK_DIR/KernelSU.apk")" 2>/dev/null))"

# Save the APK as an output artifact (always — user may need it)
cp "$KSU_APK_DIR/KernelSU.apk" "$KSU_APK_OUT"

# ----------------------------------------------------------------
# 2. Attempt to patch boot.img with ksud on CI (Strategy A)
# ----------------------------------------------------------------
log_step "2/4 — Attempting on-CI boot patching via ksud"

# Extract ksud binary from the APK
# The APK bundles lib/<arch>/libksud.so which is the ksud CLI tool
log_info "Extracting ksud binary from APK"
KSUD_BIN=""
for arch in x86_64 x86; do
  if python3 - "$KSU_APK_DIR/KernelSU.apk" "$KSU_APK_DIR" "$arch" <<'PY'
import zipfile, os, sys
apk, out, arch = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    z = zipfile.ZipFile(apk)
    target = f"lib/{arch}/libksud.so"
    if target in z.namelist():
        z.extract(target, out)
        print(f"extracted: {target}", file=sys.stderr)
        sys.exit(0)
    sys.exit(1)
except Exception as e:
    print(f"error: {e}", file=sys.stderr)
    sys.exit(1)
PY
  then
    KSUD_BIN="$KSU_APK_DIR/lib/${arch}/libksud.so"
    break
  fi
done

KSU_PATCH_OK=0
if [[ -n "$KSUD_BIN" ]] && [[ -f "$KSUD_BIN" ]]; then
  log_ok "Found ksud: $KSUD_BIN"
  # Make it executable
  chmod +x "$KSUD_BIN"

  # Copy the unrooted boot.img to patch
  cp "$REPACK_DIR/boot.img" "$KSU_WORK/boot.img"

  log_info "Running ksud boot-patch"
  # ksud may need to run from a writable directory
  cd "$KSU_WORK"
  # Try the boot-patch command (varies between KSU versions)
  if "$KSUD_BIN" boot-patch --boot "$KSU_WORK/boot.img" --output "$KSU_WORK/boot_ksu.img" 2>ksud_err.log; then
    if [[ -f "$KSU_WORK/boot_ksu.img" ]] && [[ -s "$KSU_WORK/boot_ksu.img" ]]; then
      log_ok "boot.img patched with KernelSU successfully!"
      KSU_PATCH_OK=1
    fi
  else
    log_warn "ksud boot-patch failed (expected if kernel lacks kprobes)"
    log_debug "$(cat ksud_err.log 2>/dev/null | head -10)"
  fi

  # Fallback: try the --suki flag (image-based patching, no kprobes needed)
  if [[ "$KSU_PATCH_OK" -eq 0 ]]; then
    log_info "Retrying with SUKI method (image-based patching)"
    if "$KSUD_BIN" boot-patch --boot "$KSU_WORK/boot.img" --output "$KSU_WORK/boot_ksu.img" --suki 2>ksud_err2.log; then
      if [[ -f "$KSU_WORK/boot_ksu.img" ]] && [[ -s "$KSU_WORK/boot_ksu.img" ]]; then
        log_ok "boot.img patched with KernelSU (SUKI method)!"
        KSU_PATCH_OK=1
      fi
    else
      log_warn "SUKI method also failed"
      log_debug "$(cat ksud_err2.log 2>/dev/null | head -10)"
    fi
  fi
  cd "$PROJECT_ROOT"
else
  log_warn "ksud binary not found in APK (or extraction failed)"
fi

# ----------------------------------------------------------------
# 3. Build the KSU variant zip
# ----------------------------------------------------------------
log_step "3/4 — Packaging KSU variant zip"

KSU_STAGE="$WORK_DIR/ksu_stage"
rm -rf "$KSU_STAGE"; mkdir -p "$KSU_STAGE/META-INF/com/google/android"

# --- 3a. update-binary (standard edify v3 header) ---
cat > "$KSU_STAGE/META-INF/com/google/android/update-binary" <<'BIN'
#!/sbin/sh
# One UI 9 Port — KSU variant install wrapper (edify v3)
OUTFD=$(dirname $(dirname $(dirname $(readlink /proc/self/fd/0)))) 2>/dev/null
#################
3
#################
if [ ! -e /tmp/updater ]; then
  echo "- One UI 9 Port KSU — shell fallback installer" >&2
  ZIP="$3"
  rm -rf /tmp/port; mkdir -p /tmp/port
  unzip -o "$ZIP" super.img boot.img dtbo.img modem.img init_boot.img vendor_boot.img -d /tmp/port/ >/dev/null 2>&1
  flash_part() {
    local name="$1" img="/tmp/port/$1.img"
    [ -f "$img" ] || return 0
    local slot=""
    case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
      _a|_b) slot="$(getprop ro.boot.slot_suffix)";;
    esac
    for path in "/dev/block/by-name/${name}${slot}" "/dev/block/by-name/${name}"; do
      if [ -b "$path" ]; then
        echo "- Flashing $name -> $path" >&2
        dd if="$img" of="$path" bs=8192 2>/dev/null
        return 0
      fi
    done
    echo "- WARNING: block device for $name not found, skipped" >&2
  }
  flash_part super
  flash_part boot
  flash_part init_boot
  flash_part vendor_boot
  flash_part dtbo
  flash_part modem
  rm -rf /data/dalvik-cache /data/system/dalvik-cache 2>/dev/null
  echo "- Install complete." >&2
  echo "- NOTE: KernelSU root is active (if boot patching succeeded)." >&2
  echo "- Done" >&2
  sync
  exit 0
fi
exec /tmp/updater "$@"
BIN
chmod 755 "$KSU_STAGE/META-INF/com/google/android/update-binary"

# --- 3b. Edify updater-script ---
KSU_BOOT_NOTE="KernelSU integrated (boot pre-patched on CI)"
if [[ "$KSU_PATCH_OK" -eq 0 ]]; then
  KSU_BOOT_NOTE="Standard boot (use KernelSU manager APK to patch on-device)"
fi

cat > "$KSU_STAGE/META-INF/com/google/android/updater-script" <<UPD
# ---- One UI 9 Port KSU — a53x (Samsung Galaxy A53 5G) ----
# Root: KernelSU
# Boot: ${KSU_BOOT_NOTE}
show_progress(0.1, 0);
ui_print(" ");
ui_print("========================================");
ui_print("  One UI 9 Port KSU (S26 Ultra -> A53 5G)");
ui_print("  Target: SM-A536B (a53x)");
ui_print("  Android 16 / One UI 9.0 / KernelSU");
ui_print("========================================");
ui_print(" ");

# ---- 1. Flash super partition ----
show_progress(0.2, 2);
ui_print("- Writing super partition...");
assert(package_extract_file("super.img", "/dev/block/by-name/super"),
       "ERROR: failed to write super partition");

# ---- 2. Flash boot partition ----
show_progress(0.5, 3);
ui_print("- Writing boot partition...");
assert(package_extract_file("boot.img", "/dev/block/by-name/boot_a"),
       "ERROR: failed to write boot_a");

# ---- 3. Flash auxiliary partitions when present ----
show_progress(0.7, 2);
if file_exists("dtbo.img") then
  ui_print("- Writing dtbo...");
  package_extract_file("dtbo.img", "/dev/block/by-name/dtbo_a");
endif;
if file_exists("init_boot.img") then
  ui_print("- Writing init_boot...");
  package_extract_file("init_boot.img", "/dev/block/by-name/init_boot_a");
endif;
if file_exists("vendor_boot.img") then
  ui_print("- Writing vendor_boot...");
  package_extract_file("vendor_boot.img", "/dev/block/by-name/vendor_boot_a");
endif;

# ---- 4. Post-install cleanup ----
show_progress(0.9, 2);
ui_print("- Wiping dalvik-cache...");
delete_recursive("/data/dalvik-cache");

# ---- 5. Done ----
show_progress(1.0, 3);
ui_print(" ");
ui_print("  Installation complete.");
ui_print("  Root: KernelSU");
ui_print("  First boot may take 5-10 minutes.");
ui_print("  Rebooting now...");
ui_print(" ");
UPD

# --- 3c. Copy partition images ---
cp "$REPACK_DIR/super.img" "$KSU_STAGE/super.img"
if [[ "$KSU_PATCH_OK" -eq 1 ]]; then
  log_info "Using KSU-patched boot.img"
  cp "$KSU_WORK/boot_ksu.img" "$KSU_STAGE/boot.img"
else
  log_info "Using standard (unrooted) boot.img — KSU via manager APK"
  cp "$REPACK_DIR/boot.img" "$KSU_STAGE/boot.img"
fi
for part in dtbo init_boot vendor_boot modem; do
  if [[ -f "$WORK_DIR/target_parts/${part}.img" ]]; then
    cp "$WORK_DIR/target_parts/${part}.img" "$KSU_STAGE/${part}.img"
  fi
done

# --- 3d. Manifest ---
cat > "$KSU_STAGE/PORT_INFO.txt" <<INFO
One UI 9 Port KSU — S26 Ultra -> A53 5G
========================================
Build:       $VERSION_TAG
Device:      $DEVICE_MODEL ($DEVICE_CODENAME)
One UI:      9.0 (Android 16)
Root:        KernelSU
Boot patched: $([ "$KSU_PATCH_OK" -eq 1 ] && echo "YES (on CI via ksud)" || echo "NO (patch on-device via manager APK)")
$(cat "$WORK_DIR/port_status.env" 2>/dev/null)

Flash method:
  TWRP: Install -> select this zip -> swipe to confirm
  After flash: open KernelSU manager APK to verify root status

If boot was NOT pre-patched:
  1. Install KernelSU_manager.apk after first boot
  2. Open the manager and follow the on-screen instructions
  3. The manager will patch boot.img on-device and reboot
INFO

# --- 3e. Compress ---
log_info "Packaging KSU recovery zip"
cd "$KSU_STAGE"
zip -r -q "$KSU_ZIP_OUT" ./* -x "super.img" "boot.img" "dtbo.img" "init_boot.img" "vendor_boot.img" "modem.img"
zip -q -0 "$KSU_ZIP_OUT" super.img boot.img 2>/dev/null || true
for part in dtbo init_boot vendor_boot modem; do
  [[ -f "${part}.img" ]] && zip -q -0 "$KSU_ZIP_OUT" "${part}.img" || true
done
cd "$PROJECT_ROOT"
rm -rf "$KSU_STAGE"
log_ok "KSU zip: $KSU_ZIP_OUT ($(numfmt --to=iec "$(stat -c%s "$KSU_ZIP_OUT")" 2>/dev/null))"

# --- 3f. Validate ---
if unzip -l "$KSU_ZIP_OUT" | grep -q "META-INF/com/google/android/update-binary" \
   && unzip -l "$KSU_ZIP_OUT" | grep -q "super.img"; then
  log_ok "KSU zip structure valid"
else
  die "KSU zip validation failed"
fi

# ----------------------------------------------------------------
# 4. Summary
# ----------------------------------------------------------------
log_step "4/4 — KSU variant summary"
echo
cat <<SUMMARY
${C_BOLD}${C_GREEN}========================================${C_RESET}
${C_BOLD}  KSU variant build complete!${C_RESET}
${C_BOLD}${C_GREEN}========================================${C_RESET}

  Boot patched on CI: $([ "$KSU_PATCH_OK" -eq 1 ] && echo "${C_GREEN}YES${C_RESET}" || echo "${C_YELLOW}NO (use manager APK on-device)${C_RESET}")

${C_BOLD}Output files in output/:${C_RESET}
  ${C_CYAN}$KSU_ZIP_NAME${C_RESET}    <- flash via TWRP (KSU variant)
  ${C_CYAN}$KSU_APK_NAME${C_RESET}  <- KernelSU manager (install after boot)

${C_YELLOW}NOTE:${C_RESET}
  If boot was not pre-patched, flash the ROM zip first, then install
  the KernelSU manager APK and use it to patch the kernel on-device.
SUMMARY

ok "KSU variant built successfully."
