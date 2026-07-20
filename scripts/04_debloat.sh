#!/usr/bin/env bash
# ============================================================
# 04_debloat.sh <level> — إزالة التضخيم من النظام المبورتي
# المستويات: lite (افتراضي) | standard | aggressive
#
# يعمل على مجلدات العمل المُستخرجة في work/port (tgt_system/tgt_product/...).
# يحذف دلائل APK للتطبيقات المسرودة في debloat/packages_remove.list ضمن
# المستوى المختار، مع احترام packages_keep.list.
# ============================================================
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

LEVEL="${1:-lite}"
case "$LEVEL" in
  lite|standard|aggressive) ;;
  *) die "مستوى غير صالح: $LEVEL — استخدم lite|standard|aggressive";;
esac

log_step "إزالة التضخيم (debloat) — مستوى: $LEVEL"

PORT_ROOT="$WORK_DIR/port"
[[ -d "$PORT_ROOT" ]] || die "مجلد البورت غير موجود. شغّل 03_port_framework.sh أولاً."

# الحصول على قائمة الحزم المسموح بحذفها حسب المستوى (ضمّن المستويات الأدنى)
allowed_levels=()
case "$LEVEL" in
  lite)       allowed_levels=(lite);;
  standard)   allowed_levels=(lite standard);;
  aggressive) allowed_levels=(lite standard aggressive);;
esac

# تحميل قائمة الحماية (keep) في ذاكرة
declare -A KEEP=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue
  KEEP["$line"]=1
done < "$DEBLOAT_DIR/packages_keep.list"

# قراءة keep_gapps من الإعدادات (افتراضياً true)
KEEP_GAPPS="true"
if grep -qiE '^\s*keep_gapps\s*=\s*false' "$DEBLOAT_DIR/debloat.conf" 2>/dev/null; then
  KEEP_GAPPS="false"
fi

# قوائم الحزم للحذف (مُرتّبة حسب المستوى)
declare -A TO_REMOVE=()
total_remove=0
while IFS= read -r line; do
  line="${line%%#*}"
  [[ -z "$(echo "$line" | xargs)" ]] && continue
  # الصيغة: <package> [level]
  read -r pkg lvl <<< "$(echo "$line")"
  pkg="$(echo "$pkg" | xargs)"; lvl="$(echo "${lvl:-lite}" | xargs)"
  for al in "${allowed_levels[@]}"; do
    if [[ "$lvl" == "$al" ]]; then
      # حماية GApps إن مُفعّلة
      if [[ "$KEEP_GAPPS" == "true" && "$pkg" == com.google.* ]]; then
        # GApps في قائمة keep تبقى؛ لكن بعض GApps غير أساسية (youtube music) تُحذف
        # ما لم تُسرده صراحة في keep
        : # نسمح بالحذف لأن القائمة تحدّد المُبقى منها
      fi
      # احترام قائمة keep
      if [[ -n "${KEEP[$pkg]:-}" ]]; then
        log_debug "تجاوز (keep): $pkg"
        continue
      fi
      TO_REMOVE["$pkg"]=1
      ((total_remove++)) || true
    fi
  done
done < "$DEBLOAT_DIR/packages_remove.list"

log_info "إجمالي الحزم المرشّحة للحذف: $total_remove"

# أدوات البحث في شجرة المجلدات: نبحث عن دلائل اسمها = package (بعد إزالة com.namespace إلى مسار)
# مثال: com.facebook.katana → priv-app/Facebook/ أو app/Facebook_katana/
# لذا نبحث بعدّة استراتيجيات:
#  1) دلائل اسمها يحتوي على اسم الحزمة الأخير
#  2) APK باسم الحزمة (Base.apk داخل مجلد اسمه الحزمة)
#  3) manifests مضمّنة داخل APK (نحتاج aapt2 — نتخطّى إن غير متاح)

# الأقسام المراد فحصها
SECTIONS=(
  "$PORT_ROOT/tgt_system/app"
  "$PORT_ROOT/tgt_system/priv-app"
  "$PORT_ROOT/tgt_product/app"
  "$PORT_ROOT/tgt_product/priv-app"
  "$PORT_ROOT/tgt_system_ext/app"
  "$PORT_ROOT/tgt_system_ext/priv-app"
)

removed=0; skipped=0
declare -a removed_list=()

find_and_remove_pkg() {
  local pkg="$1"
  # استخراج الاسم الأخير من الحزمة (بعد آخر '.')
  local short="${pkg##*.}"
  for section in "${SECTIONS[@]}"; do
    [[ -d "$section" ]] || continue
    # البحث عن دلائل تحتوي اسم الحزمة أو الاسم القصير (حساس لحالة الأحرف تجاهل)
    while IFS= read -r -d '' appdir; do
      local base; base="$(basename "$appdir")"
      # مطابقة تقريبية: الاسم القصير أو الحزمة الكاملة
      if echo "$base" | grep -qiE "(^|_|-)${short}($|[-_])" 2>/dev/null \
         || echo "$base" | grep -qi "^${pkg##*.}$" 2>/dev/null; then
        # تحقق إضافي: إذا بداخل المجلد APK يحتوي package= عبر aapt إن وُجد
        if command -v aapt2 >/dev/null 2>&1; then
          for apk in "$appdir"/*.apk; do
            [[ -f "$apk" ]] || continue
            if aapt2 dump packagename "$apk" 2>/dev/null | grep -qx "$pkg"; then
              rm -rf "$appdir"
              removed_list+=("$pkg ($section)")
              ((removed++)) || true
              return 0
            fi
          done
        else
          # بدون aapt2: نحذف بناءً على مطابقة الاسم (أقل دقة لكن عملي)
          log_debug "حذف (مطابقة اسم): $appdir"
          rm -rf "$appdir"
          removed_list+=("$pkg ($section)")
          ((removed++)) || true
          return 0
        fi
      fi
    done < <(find "$section" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
  done
  ((skipped++)) || true
}

log_info "بدء فحص وحذف ${#TO_REMOVE[@]} حزمة..."
for pkg in "${!TO_REMOVE[@]}"; do
  find_and_remove_pkg "$pkg"
done

# تقرير
log_step "تقرير Debloat"
log_ok "حُذف: $removed تطبيق"
log_warn "لم يُعثر عليه: $skipped تطبيق"
if [[ "$DEBUG" == "1" ]]; then
  log_debug "قائمة المحذوفات:"
  for r in "${removed_list[@]:-}"; do echo "  - $r"; done
fi

# تحديث build.prop / default.prop لإزالة مراجع الحزم المحذوفة (إلا من packages.xml)
log_info "تنظيف مراجع الحزم من packages.xml (إن أمكن)"
PACKAGES_XML="$PORT_ROOT/tgt_system/system/packages.xml"
[[ -f "$PACKAGES_XML" ]] || PACKAGES_XML="$PORT_ROOT/tgt_system/packages.xml"
if [[ -f "$PACKAGES_XML" ]] && command -v python3 >/dev/null 2>&1; then
  python3 - "$PACKAGES_XML" "${!TO_REMOVE[@]}" <<'PY'
import sys, re
path = sys.argv[1]
pkgs = set(sys.argv[2:])
with open(path, 'r', errors='ignore') as f:
    data = f.read()
orig = len(data)
for p in pkgs:
    # إزالة عناصر <package name="pkg" .../>
    data = re.sub(r'<package name="%s"[^>]*/>\s*' % re.escape(p), '', data)
    data = re.sub(r'<package name="%s"[^>]*>.*?</package>\s*' % re.escape(p), '', data, flags=re.S)
with open(path, 'w') as f:
    f.write(data)
print(f"packages.xml: {orig} → {len(data)} bytes (-{orig-len(data)})", file=sys.stderr)
PY
  log_ok "تم تنظيف packages.xml"
fi

# تسجيل الإحصاء
cat >> "$WORK_DIR/port_status.env" <<EOF
DEBLOAT_LEVEL=$LEVEL
DEBLOAT_REMOVED=$removed
DEBLOAT_SKIPPED=$skipped
EOF

log_step "التالي: bash scripts/05_patch_target.sh"
