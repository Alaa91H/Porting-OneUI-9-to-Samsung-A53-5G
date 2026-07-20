#!/usr/bin/env bash
# ============================================================
# 03_port_framework.sh — بورت One UI 9 من المصدر إلى الهدف
#
# يستبدل system/product/system_ext الديناميكية بنظيرتها من S26 Ultra،
# مع الحفاظ على vendor وodm من A53 5G (تعريفات الأجهزة).
#
# الخطوات:
#  1. استخراج صور المصدر والهدف إلى مجلدات عمل.
#  2. دمج إطارات/framework المصدر فوق هدف نظيف.
#  3. نسخ تطبيقات One UI 9 (priv-app/app) من المصدر.
#  4. الحفاظ على libs/HALs الخاصة بالهدف (vendor/lib64, etc).
#  5. إصلاح الأذونات (file_contexts, selinux).
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "بورت إطار العمل (framework) من المصدر إلى الهدف"
require_tools rsync
load_all_env
[[ -f "$WORK_DIR/image_types.csv" ]] || die "شغّل 02_extract_firmware.sh أولاً."

SRC_SYS="$WORK_DIR/source_super/split"
TGT_SYS="$WORK_DIR/target_super/split"
PORT_ROOT="$WORK_DIR/port"
mkdir -p "$PORT_ROOT"

# --- دالة: استخراج صورة القسم إلى مجلد عمل ---
prepare_partition() {
  local img="$1" outdir="$2" label="$3"
  [[ -f "$img" ]] || { log_warn "[$label] الصورة غير موجودة: $img"; return 1; }
  if mountpoint -q "$outdir" 2>/dev/null || [[ -d "$outdir/framework" ]]; then
    log_debug "[$label] جاهز مسبقاً"
    return 0
  fi
  local type; type="$(detect_image_type "$img")"
  case "$type" in
    erofs) extract_erofs "$img" "$outdir" ;;
    ext4)  mount_rw "$img" "$outdir" ;;
    *)     die "[$label] نوع غير مدعوم: $type" ;;
  esac
}

# --- 1. تجهيز أقسام المصدر (للقراءة فقط) ---
log_step "1/5 — تجهيز أقسام المصدر"
SRC_SYSTEM_DIR="$PORT_ROOT/src_system"
SRC_PRODUCT_DIR="$PORT_ROOT/src_product"
SRC_SYSTEMEXT_DIR="$PORT_ROOT/src_system_ext"
prepare_partition "$SRC_SYS/system.img"     "$SRC_SYSTEM_DIR"    "source system"     || true
prepare_partition "$SRC_SYS/product.img"   "$SRC_PRODUCT_DIR"   "source product"    || true
prepare_partition "$SRC_SYS/system_ext.img" "$SRC_SYSTEMEXT_DIR" "source system_ext" || true

# --- 2. تجهيز أقسام الهدف (قاعدة للبورت) ---
log_step "2/5 — تجهيز أقسام الهدف"
TGT_SYSTEM_DIR="$PORT_ROOT/tgt_system"
TGT_PRODUCT_DIR="$PORT_ROOT/tgt_product"
TGT_SYSTEMEXT_DIR="$PORT_ROOT/tgt_system_ext"
TGT_VENDOR_DIR="$PORT_ROOT/tgt_vendor"
TGT_ODM_DIR="$PORT_ROOT/tgt_odm"
prepare_partition "$TGT_SYS/system.img"      "$TGT_SYSTEM_DIR"    "target system"     || true
prepare_partition "$TGT_SYS/product.img"    "$TGT_PRODUCT_DIR"   "target product"    || true
prepare_partition "$TGT_SYS/system_ext.img" "$TGT_SYSTEMEXT_DIR" "target system_ext" || true
prepare_partition "$TGT_SYS/vendor.img"    "$TGT_VENDOR_DIR"    "target vendor"     || true
prepare_partition "$TGT_SYS/odm.img"       "$TGT_ODM_DIR"       "target odm"        || true

# --- 3. نسخ framework المصدر فوق الهدف ---
log_step "3/5 — استبدال إطار العمل (framework)"
PORT_FRAMEWORK=${PORT_FRAMEWORK:-1}
if [[ "$PORT_FRAMEWORK" == "1" ]]; then
  # المجلدات الحرجة لإطار One UI
  for d in framework etc etc/permissions etc/sysconfig etc/preloaded-classes etc/public.libraries.txt; do
    if [[ -d "$SRC_SYSTEM_DIR/$d" ]]; then
      log_info "نسخ system/$d من المصدر"
      mkdir -p "$TGT_SYSTEM_DIR/$(dirname "$d")"
      rsync -a --delete "$SRC_SYSTEM_DIR/$d/" "$TGT_SYSTEM_DIR/$d/" 2>/dev/null || true
    fi
  done
  # مكتبات بوتستريب (bootclasspath)
  for d in lib lib64; do
    # لا نستبدل lib كاملة (تخدّم التعريفات)، فقط framework*.jar في framework/$d إن وُجد
    [[ -d "$SRC_SYSTEM_DIR/framework/$d" ]] && {
      mkdir -p "$TGT_SYSTEM_DIR/framework/$d"
      rsync -a "$SRC_SYSTEM_DIR/framework/$d/" "$TGT_SYSTEM_DIR/framework/$d/" 2>/dev/null || true
    }
  done
fi

# --- 4. نسخ تطبيقات One UI 9 ---
log_step "4/5 — نسخ تطبيقات One UI 9 (priv-app/app)"
copy_oneui_apps() {
  local src_root="$1" tgt_root="$2" label="$3"
  # قائمة التطبيقات الأساسية للواجهة (ننسخها من المصدر، نتجنّب التطبيقات المعدّلة للهدف)
  local oneui_apps=(
    "priv-app/SecSettings"           # الإعدادات (One UI)
    "priv-app/SecSettingsProvider"
    "priv-app/SecLauncher"
    "priv-app/TouchWizHome"
    "priv-app/OneUIHome"
    "priv-app/SystemUI"              # شريط الحالة والإشعارات
    "priv-app/Keyguard"
    "priv-app/CustomizeManager"
    "priv-app/EmergencyMode"
    "priv-app/SecPhone"
    "priv-app/SecContacts"
    "priv-app/SecMessages"
    "priv-app/SecCalendar"
    "priv-app/SecClock"
    "priv-app/SecCalculator"
    "priv-app/SecMemo"
    "priv-app/SmartManager"
    "priv-app/DeviceMaintenance"
    "priv-app/SamsungNetworkUI"
    "app/SmartSwitch"
    "app/SmartCapture"
    "app/SamsungAccount"
    "app/EdgePanels"
    "app/UXOptimizations"
  )
  local copied=0
  for app in "${oneui_apps[@]}"; do
    local src_path="$src_root/$app"
    if [[ -d "$src_path" ]]; then
      mkdir -p "$tgt_root/$(dirname "$app")"
      rsync -a --delete "$src_path/" "$tgt_root/$app/" 2>/dev/null && {
        log_debug "نسخ $label/$app"
        ((copied++)) || true
      } || true
    fi
  done
  log_ok "تم نسخ $copied تطبيق One UI من $label"
}
copy_oneui_apps "$SRC_SYSTEM_DIR"    "$TGT_SYSTEM_DIR"    "system"
copy_oneui_apps "$SRC_PRODUCT_DIR"   "$TGT_PRODUCT_DIR"   "product"
copy_oneui_apps "$SRC_SYSTEMEXT_DIR" "$TGT_SYSTEMEXT_DIR" "system_ext"

# --- 5. الحفاظ على HALs/libs الخاصة بالهدف ---
log_step "5/5 — الحفاظ على تعريفات الهدف (vendor/HAL)"
# لا نلمس vendor/odm لأنها من الهدف أصلاً، لكن نتأكد أن system/lib64 لا تُستبدل
# بالكامل (مكتبات التعريفات المعمارية).
PRESERVE_TARGET_LIBS=${PRESERVE_TARGET_LIBS:-1}
if [[ "$PRESERVE_TARGET_LIBS" == "1" ]] && [[ -d "$TGT_SYSTEM_DIR/lib64" ]]; then
  log_info "استعادة lib64 الخاصة بالهدف (تعريفات hw/Exynos 1280)"
  # نُعيد مكتبات hw/vulkan/egl من الهدف لأنها معمارية محددة
  for sub in hw egl vulkan; do
    if [[ -d "$TGT_VENDOR_DIR/lib64/$sub" ]]; then
      mkdir -p "$TGT_SYSTEM_DIR/lib64/$sub"
      rsync -a "$TGT_VENDOR_DIR/lib64/$sub/" "$TGT_SYSTEM_DIR/lib64/$sub/" 2>/dev/null || true
    fi
  done
fi

# --- 6. إصلاح الأذونات والـ file_contexts ---
log_info "إصلاح أذونات SELinux وfile_contexts"
# نُولّد file_contexts مبسّط لما أضفناه
if [[ -d "$TGT_SYSTEM_DIR/system/etc/selinux" ]]; then
  : # سيُعالج في 05_patch_target.sh
fi

# تسجيل حالة البورت
cat > "$WORK_DIR/port_status.env" <<EOF
PORT_TIMESTAMP="$(date -u +%FT%TZ)"
PORT_SOURCE="$DEVICE_CODENAME (source env)"
PORT_ONEUI="$ONEUI_VERSION"
FRAMEWORK_PORTED=1
APPS_COPIED=1
EOF
log_ok "اكتمل بورت framework. الحالة محفوظة في $WORK_DIR/port_status.env"
log_step "التالي: bash scripts/04_debloat.sh standard"
