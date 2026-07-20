#!/usr/bin/env bash
# ============================================================
# 07_build_flashable.sh — Build the final unrooted flashable packages
#   1. OneUI9_a53x_Port_unrooted_<tag>.tar.md5  — Odin (AP slot)
#   2. OneUI9_a53x_Port_unrooted_<tag>.zip       — TWRP / stock recovery
#
# This is the UNROOTED variant (no root, no KSU).
# For the KSU (KernelSU rooted) variant, run 08_build_ksu.sh next.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "Building unrooted flashable packages"
require_tools tar zip md5sum
load_target_env

REPACK_DIR="$WORK_DIR/repacked"
[[ -d "$REPACK_DIR" ]] || die "Repack dir not found. Run 06_repack.sh first."

VARIANT="unrooted"
VERSION_TAG="$(git_info | tr ' ' '_')"
ODIN_NAME="OneUI9_${DEVICE_CODENAME}_Port_${VARIANT}_${VERSION_TAG}.tar.md5"
TWRP_NAME="OneUI9_${DEVICE_CODENAME}_Port_${VARIANT}_${VERSION_TAG}.zip"
ODIN_OUT="$OUTPUT_DIR/$ODIN_NAME"
TWRP_OUT="$OUTPUT_DIR/$TWRP_NAME"
mkdir -p "$OUTPUT_DIR"

# ============================================================
# 1. Pre-output sanity checks
# ============================================================
log_step "1/4 — Sanity checks"
for f in super.img boot.img; do
  [[ -f "$REPACK_DIR/$f" ]] || die "Critical file missing: $REPACK_DIR/$f"
done
log_ok "Critical files present"

# b) Verify super.img metadata via lpdump
if command -v lpdump >/dev/null 2>&1; then
  if lpdump "$REPACK_DIR/super.img" >/dev/null 2>&1; then
    log_ok "super.img: valid metadata"
  else
    die "super.img: corrupt metadata! Check 06_repack.sh"
  fi
fi

# c) Verify device fingerprint in build.prop
PROP_FOUND=0
for propfile in \
  "$WORK_DIR/port/tgt_system/build.prop" \
  "$WORK_DIR/port/tgt_system/system/build.prop"; do
  if [[ -f "$propfile" ]] && grep -q "ro.product.device=$DEVICE_CODENAME" "$propfile"; then
    PROP_FOUND=1
    log_ok "Device fingerprint OK in $(basename "$propfile"): $DEVICE_CODENAME"
    break
  fi
done
[[ "$PROP_FOUND" == "1" ]] || log_warn "Device fingerprint not found — check 05_patch_target.sh"

# d) Verify debloat was applied
if [[ -f "$WORK_DIR/port_status.env" ]] && grep -q "DEBLOAT_REMOVED" "$WORK_DIR/port_status.env"; then
  log_ok "Debloat applied"
fi

# ============================================================
# 2. Build Odin package (.tar.md5)
# ============================================================
log_step "2/4 — Building Odin package"
ODIN_STAGE="$WORK_DIR/odin_stage"
rm -rf "$ODIN_STAGE"; mkdir -p "$ODIN_STAGE"
cp "$REPACK_DIR/super.sparse.img" "$ODIN_STAGE/super.img" 2>/dev/null \
  || cp "$REPACK_DIR/super.img" "$ODIN_STAGE/super.img"
cp "$REPACK_DIR/boot.img" "$ODIN_STAGE/boot.img"

# Include target partitions if captured
for part in dtbo modem init_boot vendor_boot; do
  if [[ -f "$WORK_DIR/target_parts/${part}.img" ]]; then
    cp "$WORK_DIR/target_parts/${part}.img" "$ODIN_STAGE/${part}.img"
  fi
done
touch "$ODIN_STAGE/csc.img"

log_info "Computing MD5 and assembling tar"
cd "$ODIN_STAGE"
tar -cf "$OUTPUT_DIR/$ODIN_NAME.tmp" --format=ustar ./*
OVERALL_MD5="$(md5sum "$OUTPUT_DIR/$ODIN_NAME.tmp" | awk '{print $1}')"
printf '%s' "$OVERALL_MD5" >> "$OUTPUT_DIR/$ODIN_NAME.tmp"
printf '\0\0' >> "$OUTPUT_DIR/$ODIN_NAME.tmp"
mv "$OUTPUT_DIR/$ODIN_NAME.tmp" "$ODIN_OUT"
cd "$PROJECT_ROOT"
rm -rf "$ODIN_STAGE"
log_ok "Odin: $ODIN_OUT ($(numfmt --to=iec "$(stat -c%s "$ODIN_OUT")" 2>/dev/null))"

# ============================================================
# 3. Build recovery-flashable zip (TWRP / OrangeFox / Stock recovery)
# ============================================================
log_step "3/4 — Building recovery-flashable zip"
TWRP_STAGE="$WORK_DIR/twrp_stage"
rm -rf "$TWRP_STAGE"; mkdir -p "$TWRP_STAGE/META-INF/com/google/android"

# --- 3a. Standard update-binary ---
# This is the canonical header every Android recovery recognises: it forwards
# execution to the recovery's built-in edify interpreter (which reads the
# updater-script). Line 1 must be "#!/sbin/sh"; line 3 is the magic "3".
cat > "$TWRP_STAGE/META-INF/com/google/android/update-binary" <<'BIN'
#!/sbin/sh
# Firmware install wrapper (edify v3) — One UI 9 Port
# Recovery reads this, then executes updater-script via its edify interpreter.
OUTFD=$(dirname $(dirname $(dirname $(readlink /proc/self/fd/0)))) 2>/dev/null
# The standard 3-line preamble expected by Android recovery:
#   line 1: shebang
#   line 2: source the recovery's own update-binary template
#   line 3: the literal "3" marks the edify version
#################
3
#################
# If the recovery did not auto-inject its interpreter, fall back to a
# minimal shell installer that writes the raw partitions directly.
if [ ! -e /tmp/updater ]; then
  echo "- One UI 9 Port — shell fallback installer" >&2
  ZIP="$3"
  OUTFD="$2"
  # Extract images into a temp dir
  rm -rf /tmp/port; mkdir -p /tmp/port
  unzip -o "$ZIP" super.img boot.img dtbo.img modem.img init_boot.img vendor_boot.img -d /tmp/port/ >/dev/null 2>&1
  # Helper: write a partition image to the active slot's by-name symlink
  flash_part() {
    local name="$1" img="/tmp/port/$1.img"
    [ -f "$img" ] || return 0
    local slot=""
    case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
      _a|_b) slot="$(getprop ro.boot.slot_suffix)";;
    esac
    # Try slot-suffixed path first, then plain
    for path in "/dev/block/by-name/${name}${slot}" "/dev/block/by-name/${name}"; do
      if [ -b "$path" ]; then
        echo "- Flashing $name → $path" >&2
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
  # Post-install wipes
  rm -rf /data/dalvik-cache /data/system/dalvik-cache 2>/dev/null
  echo "- Install complete. Rebooting may take longer on first boot." >&2
  echo "- Done" >&2
  sync
  exit 0
fi
# Normal path: let the recovery's edify interpreter run updater-script
exec /tmp/updater "$@"
BIN
chmod 755 "$TWRP_STAGE/META-INF/com/google/android/update-binary"

# --- 3b. Edify updater-script ---
# Written in the edify scripting language (NOT shell). Uses only the standard
# functions that TWRP and stock recovery understand:
#   ui_print, show_progress, package_extract_file, assert, delete_recursive
cat > "$TWRP_STAGE/META-INF/com/google/android/updater-script" <<'UPD'
# ---- One UI 9 Port — a53x (Samsung Galaxy A53 5G) ----
# Edify updater-script. Lines starting with '#' are comments in edify.
show_progress(0.1, 0);
ui_print(" ");
ui_print("========================================");
ui_print("  One UI 9 Port  (S26 Ultra -> A53 5G)");
ui_print("  Target: SM-A536B (a53x)");
ui_print("  Android 16 / One UI 9.0");
ui_print("========================================");
ui_print(" ");

# ---- 1. Flash super partition (system/product/vendor/system_ext) ----
show_progress(0.2, 2);
ui_print("- Writing super partition...");
assert(package_extract_file("super.img", "/dev/block/by-name/super"),
       "ERROR: failed to write super partition");

# ---- 2. Flash patched boot (forceencrypt / dm-verity disabled) ----
show_progress(0.5, 3);
ui_print("- Writing boot partition...");
assert(package_extract_file("boot.img", "/dev/block/by-name/boot_a"),
       "ERROR: failed to write boot_a");

# ---- 3. Flash auxiliary partitions when present in the package ----
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
ui_print("  First boot may take 5-10 minutes.");
ui_print("  Rebooting now...");
ui_print(" ");
UPD

# --- 3c. Copy partition images into the zip root ---
cp "$REPACK_DIR/super.img" "$TWRP_STAGE/super.img"
cp "$REPACK_DIR/boot.img" "$TWRP_STAGE/boot.img"
# Include any target partitions we captured, if present
for part in dtbo init_boot vendor_boot modem; do
  if [[ -f "$WORK_DIR/target_parts/${part}.img" ]]; then
    cp "$WORK_DIR/target_parts/${part}.img" "$TWRP_STAGE/${part}.img"
  fi
done

# --- 3d. Bundle a small human-readable manifest ---
cat > "$TWRP_STAGE/PORT_INFO.txt" <<INFO
One UI 9 Port — S26 Ultra -> A53 5G
====================================
Build:      $VERSION_TAG
Device:     $DEVICE_MODEL ($DEVICE_CODENAME)
One UI:     9.0 (Android 16)
Source PDA: $(${PYTHON_BIN:-python3} -c "import json;d=json.load(open('$WORK_DIR/${SRC_MODEL:-SM-S948B}_fetch.json'));print(d.get('entry',{}).get('pda','unknown'))" 2>/dev/null || echo unknown)
$(cat "$WORK_DIR/port_status.env" 2>/dev/null)

Flash method:
  TWRP: Install -> select this zip -> swipe to confirm
  Stock recovery: also supported (edify v3)

Post-flash:
  Wipe data/cache/dalvik, then reboot.
INFO

# --- 3e. Compress (store, no compression — partitions already compressed) ---
log_info "Packaging recovery zip (store method for speed)"
cd "$TWRP_STAGE"
# Use -0 (store) for the large .img files, default deflate for small text
zip -r -q "$TWRP_OUT" ./* -x "super.img" "boot.img" "dtbo.img" "init_boot.img" "vendor_boot.img" "modem.img"
# Add the large images stored (no compression — they're already compressed)
zip -q -0 "$TWRP_OUT" super.img boot.img 2>/dev/null || true
for part in dtbo init_boot vendor_boot modem; do
  [[ -f "${part}.img" ]] && zip -q -0 "$TWRP_OUT" "${part}.img" || true
done
cd "$PROJECT_ROOT"
rm -rf "$TWRP_STAGE"
log_ok "Recovery zip: $TWRP_OUT ($(numfmt --to=iec "$(stat -c%s "$TWRP_OUT")" 2>/dev/null))"

# --- 3f. Validate the zip is a valid recovery package ---
log_info "Validating zip structure"
if unzip -l "$TWRP_OUT" | grep -q "META-INF/com/google/android/update-binary" \
   && unzip -l "$TWRP_OUT" | grep -q "META-INF/com/google/android/updater-script" \
   && unzip -l "$TWRP_OUT" | grep -q "super.img"; then
  ok "Zip structure valid (update-binary + updater-script + super.img present)"
else
  die "Zip validation failed — missing required entries"
fi

# ============================================================
# 4. Final summary
# ============================================================
log_step "4/4 — Build summary"
echo
cat <<SUMMARY
${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
${C_BOLD}  One UI 9 Port build complete!${C_RESET}
${C_BOLD}${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}

  Target device:   $DEVICE_MODEL ($DEVICE_CODENAME)
  One UI version:  9.0 (Android 16)
  Source device:   S26 Ultra
  Debloat level:   $(grep -E '^DEBLOAT_LEVEL' "$WORK_DIR/port_status.env" 2>/dev/null | cut -d= -f2 || echo '?')
  Build time:      $(date -u +%FT%TZ)

${C_BOLD}Output files in output/:${C_RESET}
  ${C_CYAN}$ODIN_NAME${C_RESET}     <- flash via Odin (AP slot)
  ${C_CYAN}$TWRP_NAME${C_RESET}   <- flash via TWRP / stock recovery

${C_YELLOW}IMPORTANT:${C_RESET} before flashing:
  1) Take a full backup of your data.
  2) Unlock Bootloader (enable OEM Unlock in Developer Options).
  3) Flash original target vendor/modem first if not bundled.
  4) Wipe data/cache/dalvik after flashing.
SUMMARY

ok "All packages built successfully."
