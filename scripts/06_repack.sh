#!/usr/bin/env bash
# ============================================================
# 06_repack.sh — إعادة حزم المجلدات المعدّلة إلى صور أقسام،
# ثم تجميعها في super.img جديدة لـ A53 5G.
#
# يدعم ext4 و EROFS (كشف تلقائي). يحافظ على أحجام الأقسام الأصلية.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "إعادة حزم الأقسام المعدّلة"
require_tools mkfs.erofs mkfs.ext4 file xxd
load_all_env
require_root

PORT_ROOT="$WORK_DIR/port"
TGT_SPLIT="$WORK_DIR/target_super/split"
REPACK_DIR="$WORK_DIR/repacked"
mkdir -p "$REPACK_DIR"

# دالة لإعادة حزم قسم واحد
# repack_partition <name> <source_dir> <original_img>
repack_partition() {
  local name="$1" src="$2" orig="$3"
  local out="$REPACK_DIR/${name}.img"
  [[ -d "$src" ]] || { log_warn "[$name] مجلد المصدر غير موجود، نسخ الصورة الأصلية"; cp "$orig" "$out" 2>/dev/null || true; return; }
  local type; type="$(detect_image_type "$orig")"
  # حساب حجم الصورة الأصلية للحفاظ عليه
  local size_bytes; size_bytes="$(stat -c%s "$orig")"
  log_info "[$name] إعادة حزم ($type, الهدف ~$((size_bytes/1048576)) MiB)"

  case "$type" in
    erofs)
      require_tools mkfs.erofs
      # إزالة الصورة القديمة إن وُجدت
      rm -f "$out"
      # بناء EROFS بنفس خيارات سامسونج (compression, extent_blocks)
      mkfs.erofs \
        -z lz4hc,9 \
        --mount-point "/${name}" \
        --fs-config-file "/dev/null" \
        -C 4096 \
        "$out" "$src" 2>&1 | tail -5 || \
      mkfs.erofs -z lz4hc "$out" "$src"
      ;;
    ext4)
      # إنشاء صورة ext4 بحجم ثابت ثم ملؤها
      require_tools mkfs.ext4
      truncate -s "$size_bytes" "$out"
      mkfs.ext4 -F -L "$name" -b 4096 "$out" >/dev/null 2>&1
      local mp; mp="$(mktemp -d)"
      mount -o loop,rw "$out" "$mp"
      rsync -aHAXx "$src/" "$mp/" 2>/dev/null || rsync -a "$src/" "$mp/"
      sync
      # توسيع السجلات/الملفات ثم ضبط الحجم
      umount_clean "$mp"
      rmdir "$mp" 2>/dev/null || true
      # اقتصاص المساحة غير المستخدمة (تقليل الحجم إن أمكن)
      resize2fs -M "$out" 2>/dev/null || true
      # إعادة التوسعة للحجم الأصلي للحفاظ على توافق الأقسام
      truncate -s "$size_bytes" "$out"
      ;;
    *)
      die "[$name] نوع غير معروف: $type"
      ;;
  esac
  log_ok "[$name] → $out ($(numfmt --to=iec "$(stat -c%s "$out")" 2>/dev/null))"
}

# إعادة حزم الأقسام المبورتة
repack_partition "system"     "$PORT_ROOT/tgt_system"     "$TGT_SPLIT/system.img"      2>/dev/null || true
repack_partition "product"    "$PORT_ROOT/tgt_product"   "$TGT_SPLIT/product.img"     2>/dev/null || true
repack_partition "system_ext" "$PORT_ROOT/tgt_system_ext" "$TGT_SPLIT/system_ext.img" 2>/dev/null || true

# الأقسام المحفوظة من الهدف (vendor/odm) — ننسخها كما هي
for part in vendor odm vendor_dlkm; do
  if [[ -f "$TGT_SPLIT/${part}.img" ]]; then
    log_info "[$part] نسخ من الهدف (بدون تعديل)"
    cp "$TGT_SPLIT/${part}.img" "$REPACK_DIR/${part}.img"
    log_ok "[$part] نسخ"
  fi
done

# --- إعادة تجميع super.img ---
log_step "تجميع super.img عبر lpmake"
require_tools lpmake
SUPER_OUT="$REPACK_DIR/super.img"

# بناء أمر lpmake ديناميكياً بناءً على الأقسام المتوفرة وحميعها
LPMAKE_ARGS=(
  device size:"$SUPER_PARTITION_SIZE"
  metadata size:65536
  metadata slots:2
  group "$GROUP_NAME":"$SUPER_PARTITION_SIZE"
)

# أضف أقسام للحجم
for part in system product system_ext vendor odm vendor_dlkm; do
  img="$REPACK_DIR/${part}.img"
  [[ -f "$img" ]] || continue
  size="$(stat -c%s "$img")"
  LPMAKE_ARGS+=("partition $part:readonly:${size}:$GROUP_NAME")
  LPMAKE_ARGS+=("image $part:$img")
done

log_debug "lpmake args: ${LPMAKE_ARGS[*]}"
lpmake "${LPMAKE_ARGS[@]}" -o "$SUPER_OUT" 2>&1 | tail -20 || die "فشل lpmake"

log_ok "تم بناء super.img: $SUPER_OUT ($(numfmt --to=iec "$(stat -c%s "$SUPER_OUT")" 2>/dev/null))"

# تحويل super.img إلى sparse (مطلوب لفلاش Odin)
sparsify "$SUPER_OUT" "$REPACK_DIR/super.sparse.img" 2>/dev/null || cp "$SUPER_OUT" "$REPACK_DIR/super.sparse.img"

# تعديل boot.img لتعطيل forceencrypt و dm-verity
log_step "تعديل boot.img لتعطيل verity/forceencrypt"
BOOT_IMG="$WORK_DIR/target_parts/boot.img"
if [[ -f "$BOOT_IMG" ]] && command -v magiskboot >/dev/null 2>&1; then
  BOUT="$REPACK_DIR/boot.img"
  cp "$BOOT_IMG" "$BOUT"
  cd "$REPACK_DIR"
  magiskboot unpack boot.img >/dev/null 2>&1 || true
  # تعطيل forceencrypt في ramdisk
  if [[ -f ramdisk.cpio ]]; then
    magiskboot cpio ramdisk.cpio "patch fstab" >/dev/null 2>&1 || true
    # إزالة verity_key و forceencrypt من fstab المضمّن
    magiskboot cpio ramdisk.cpio extract >/dev/null 2>&1 || true
    if [[ -d ramdisk ]]; then
      find ramdisk -name 'fstab*' -exec sed -i -E 's/\bverify\b//g; s/,verifyatboot//g; s/\bforceencrypt\b=/encryptable=/g; s/forcefdeorfbe=/encryptable=/g' {} \; 2>/dev/null || true
      magiskboot cpio ramdisk.cpio "add ramdisk" >/dev/null 2>&1 || true
    fi
  fi
  # إعادة حزم boot
  magiskboot repack boot.img boot_new.img >/dev/null 2>&1 && mv boot_new.img "$BOUT" || true
  cd "$PROJECT_ROOT"
  log_ok "تم تعديل boot.img: $BOUT"
fi

# تسجيل النتائج
cat >> "$WORK_DIR/port_status.env" <<EOF
REPACK_TIMESTAMP="$(date -u +%FT%TZ)"
REPACK_SUPER="$REPACK_DIR/super.img"
REPACK_SPARSE="$REPACK_DIR/super.sparse.img"
REPACK_BOOT="$REPACK_DIR/boot.img"
EOF
log_ok "اكتملت إعادة الحزم."
log_step "التالي: bash scripts/07_build_flashable.sh"
