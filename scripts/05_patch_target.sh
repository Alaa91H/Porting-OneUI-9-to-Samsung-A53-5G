#!/usr/bin/env bash
# ============================================================
# 05_patch_target.sh — تطبيق تعديلات build.prop و vintf و SELinux
# على صورة النظام المبورتي، لتناسب A53 5G.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

log_step "تطبيق تعديلات الهدف (build.prop / vintf / selinux)"
load_target_env
require_tools sed awk

PORT_ROOT="$WORK_DIR/port"
[[ -d "$PORT_ROOT/tgt_system" ]] || die "مجلد البورت غير جاهز. شغّل 03/04 أولاً."

# تطبيق زوج مفتاح/قيمة على ملف prop
apply_prop() {
  local file="$1" key="$2" value="$3"
  [[ -f "$file" ]] || return 1
  if grep -qE "^${key}=" "$file"; then
    # استبدال القيمة الحالية
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$file"
  else
    # إضافة المفتاح في النهاية
    echo "${key}=${value}" >> "$file"
  fi
}

# تطبيق ملف build.prop.patch (الصيغة KEY=value لكل سطر، # تعليق)
apply_prop_patch_file() {
  local patch="$PATCHES_DIR/build.prop.patch"
  local target="$1"
  [[ -f "$target" ]] || return 1
  log_info "تطبيق $(basename "$patch") على $(basename "$target")"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || continue
    local key val
    key="${line%%=*}"; val="${line#*=}"
    # استبدال متغيرات التاريخ/البيئة في القيمة
    val="$(eval echo "$val" 2>/dev/null || echo "$val")"
    apply_prop "$target" "$key" "$val"
  done < "$patch"
}

# --- 1. تطبيق patch على كل ملفات build.prop الموجودة ---
log_step "1/3 — تعديل build.prop"
for f in \
  "$PORT_ROOT/tgt_system/build.prop" \
  "$PORT_ROOT/tgt_system/system/build.prop" \
  "$PORT_ROOT/tgt_product/build.prop" \
  "$PORT_ROOT/tgt_system_ext/build.prop" \
  "$PORT_ROOT/tgt_vendor/build.prop" \
  "$PORT_ROOT/tgt_system/system/etc/prop.default" \
  "$PORT_ROOT/tgt_vendor/default.prop" \
  "$PORT_ROOT/tgt_vendor/vendor/build.prop"; do
  [[ -f "$f" ]] && apply_prop_patch_file "$f" || true
done
log_ok "تم تحديث خصائص البناء لـ $DEVICE_CODENAME"

# --- 2. ملف فحص توافق Vendor Interface (vintf) ---
log_step "2/3 — ملف توافق vendor interface"
VINTF_DIR="$PORT_ROOT/tgt_system/system/etc/vintf"
mkdir -p "$VINTF_DIR"
# مصفوفة توافق تخبر النظام أن vendor@14 متوافق مع system@16
cat > "$VINTF_DIR/compatibility_matrix.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<compatibility-matrix version="1.0" type="framework" level="14">
  <sepolicy>
    <kernel-sepolicy-version>30</kernel-sepolicy-version>
  </sepolicy>
</compatibility-matrix>
XML
log_ok "تم إنشاء compatibility_matrix.xml"

# --- 3. تعديلات SELinux و dm-verity ---
log_step "3/3 — تعديلات SELinux و verity"
# تعطيل strict SELinux مؤقتاً (enforcing → permissive في boot تم في 06)
SELINUX_DIR="$PORT_ROOT/tgt_system/system/etc/selinux"
if [[ -d "$SELINUX_DIR" ]]; then
  # السماح بتشغيل النظام المعدّل دون حظر
  if [[ -f "$SELINUX_DIR/plat_sepolicy.cil" ]]; then
    # إضافة قاعدة permissive شاملة لتهدئة التطبيقات المنسوخة
    cat >> "$SELINUX_DIR/plat_sepolicy.cil" <<'CIL'
; One UI 9 Port — قواعد استرخاء مؤقتة لتطبيقات المنسوخة
(typeattributeset untrusted_app_29 (untrusted_app_25))
(typepermissive untrusted_app_25)
CIL
    log_ok "تم تعديل sepolicy (permissive للتطبيقات المنسوخة)"
  fi
fi

# تعطيل dm-verity في fstab إن وُجد
FSTAB="$PORT_ROOT/tgt_vendor/fstab.exynos1280"
[[ -f "$FSTAB" ]] || FSTAB="$PORT_ROOT/tgt_vendor/etc/fstab.qcom"
if [[ -f "$FSTAB" ]]; then
  log_info "تعطيل verity في $FSTAB"
  sed -i -E 's/\bverify\b//g; s/,verifyatboot//g; s/\bforceencrypt\b=/encryptable=/g' "$FSTAB"
  log_ok "تم تعديل fstab"
fi

# --- 4. حذف بصمات SafetyNet القديمة إن وُجدت ---
for leftover in \
  "$PORT_ROOT/tgt_system/system/etc/safetynet" \
  "$PORT_ROOT/tgt_product/etc/safetynet"; do
  [[ -e "$leftover" ]] && rm -rf "$leftover" && log_debug "حذف $leftover"
done

log_ok "اكتمل تطبيق التعديلات."
log_step "التالي: bash scripts/06_repack.sh"
