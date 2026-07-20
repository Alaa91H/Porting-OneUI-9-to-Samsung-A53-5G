#!/usr/bin/env bash
# ============================================================
# 02_extract_firmware.sh — استخراج الأقسام من حزم .tar.md5 سامسونج
# ثم فك super.img إلى أقسام ديناميكية، وتحويل sparse → raw.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "استخراج الأقسام من الفيرموير"
require_tools tar xxd file
load_all_env
[[ -f "$WORK_DIR/firmware_paths.env" ]] || die "شغّل 01_download_firmware.sh أولاً."
source "$WORK_DIR/firmware_paths.env"

SRC_ROOT="$WORK_DIR/source"
TGT_ROOT="$WORK_DIR/target"
mkdir -p "$SRC_ROOT" "$TGT_ROOT"

# --- 1. فك حزمة tar.md5 ---
extract_tar() {
  local tarfile="$1" outdir="$2" name="$3"
  log_info "فك $name: $(basename "$tarfile")"
  # ملفات سامسونج قد تكون مزدوجة الضغط: .tar.md5 أو .tar (داخلها AP/BL/CP/CSC)
  # قد تكون مضغوطة بـ lz4/zstd أحياناً — نتعامل مع الحالة العامة tar.
  tar -xf "$tarfile" -C "$outdir" 2>/dev/null || tar -xOf "$tarfile" | tar -xf - -C "$outdir"
  log_ok "تم فك $name → $outdir"
}
extract_tar "$SOURCE_FIRMWARE" "$SRC_ROOT" "المصدر"
extract_tar "$TARGET_FIRMWARE" "$TGT_ROOT" "الهدف"

# --- 2. تحديد ملفات الأقسام داخل كل حزمة ---
# سامسونج تسمّي الملفات: AP_<model>_<ver>.tar.md5 يحتوي على boot.img, system.img, vendor.img, ...
# و BL_*.tar.md5 للحذاء، CP_*.tar.md5 للمودم، CSC_*.tar.md5 للـ csc.
find_part() {
  local root="$1" part="$2"
  # ابحث عن ملف باسم القسم (system.img / vendor.img / boot.img / super.img ...)
  local found
  found="$(find "$root" -type f \( -iname "${part}.img" -o -iname "${part}_a.img" -o -iname "${part}.img.ext4" \) 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] && { echo "$found"; return 0; }
  # قد يكون داخل AP*.tar.md5 فرعي
  found="$(find "$root" -type f -iname "*.tar.md5" -exec sh -c 'tar -tf "$1" 2>/dev/null | grep -i "/'"$part"'\.img$"' _ {} \; 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    # استخرج القسم من الحزمة الفرعية
    local ap; ap="$(find "$root" -type f -iname "AP*.tar.md5" -o -iname "*AP*.tar.md5" | head -1)"
    [[ -n "$ap" ]] && tar -xf "$ap" -C "$root" "$found" 2>/dev/null || tar -xf "$(dirname "$found")" -C "$root" 2>/dev/null || true
    echo "$root/$found"
    return 0
  fi
  return 1
}

# --- 3. استخراج super.img وتحويله لـ raw ثم فكّه ---
process_super() {
  local root="$1" label="$2" outdir="$3"
  local super
  super="$(find_part "$root" "super")" || { log_warn "لم يُعثر على super.img في $label"; return 1; }
  log_info "[$label] معالجة super.img: $super"
  local raw="$outdir/super.raw.img"
  rawize "$super" "$raw"            # sparse → raw
  unpack_super "$raw" "$outdir/split"
  log_ok "[$label] تم فك super → $outdir/split"
  ls -la "$outdir/split" 2>/dev/null || true
}

SRC_SUPER_DIR="$WORK_DIR/source_super"
TGT_SUPER_DIR="$WORK_DIR/target_super"
mkdir -p "$SRC_SUPER_DIR" "$TGT_SUPER_DIR"
process_super "$SRC_ROOT" "المصدر" "$SRC_SUPER_DIR" || true
process_super "$TGT_ROOT" "الهدف" "$TGT_SUPER_DIR" || true

# --- 4. استخراج أقسام الهدف غير الديناميكية (boot, init_boot, dtbo, modem) ---
log_step "استخراج أقسام الهدف المحفوظة (boot/init_boot/dtbo/modem)"
TGT_PARTS_DIR="$WORK_DIR/target_parts"
mkdir -p "$TGT_PARTS_DIR"
for part in boot init_boot vendor_boot dtbo modem radio; do
  p="$(find_part "$TGT_ROOT" "$part")" || { log_debug "[$part] غير موجود في الهدف"; continue; }
  dst="$TGT_PARTS_DIR/${part}.img"
  rawize "$p" "$dst"
  log_ok "[$part] ← $dst"
done

# --- 5. تحديد نوع كل قسم (ext4/erofs) وتسجيله ---
log_step "كشف أنواع الصور"
IMG_TYPES="$WORK_DIR/image_types.csv"
: > "$IMG_TYPES"
for img in "$SRC_SUPER_DIR"/split/*.img "$TGT_SUPER_DIR"/split/*.img "$TGT_PARTS_DIR"/*.img; do
  [[ -f "$img" ]] || continue
  t="$(detect_image_type "$img")"
  echo "$(basename "$img"),$t,$img" >> "$IMG_TYPES"
  log_info "$(basename "$img") → $t"
done

log_ok "تم تجهيز كل الصور."
log_step "التالي: bash scripts/03_port_framework.sh"
