#!/usr/bin/env bash
# ============================================================
# lib/common.sh — دوال مشتركة لجميع سكربتات البورت
# يجب تحميله عبر: source "$(dirname "$0")/lib/common.sh"
# ============================================================

set -Eeuo pipefail

# --- مسارات المشروع ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config"
DEBLOAT_DIR="$PROJECT_ROOT/debloat"
PATCHES_DIR="$PROJECT_ROOT/patches"
WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/output}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$PROJECT_ROOT/downloads}"

# --- مستوى السجلات ---
LOG_LEVEL="${LOG_LEVEL:-INFO}"
DEBUG="${DEBUG:-0}"
[[ "${1:-}" == "--debug" ]] && DEBUG=1 && LOG_LEVEL=DEBUG

# --- ألوان ---
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_RED="\033[31m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
  C_BLUE="\033[34m"; C_MAGENTA="\033[35m"; C_CYAN="\033[36m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
  C_MAGENTA=""; C_CYAN=""; C_BOLD=""
fi

# ============================================================
# دوال السجل
# ============================================================
_log() {
  local color="$1" level="$2"; shift 2
  local ts; ts="$(date +'%H:%M:%S')"
  printf "${color}[%s] [%-5s] %s${C_RESET}\n" "$ts" "$level" "$*" >&2
}
log_info()    { _log "$C_CYAN"   "INFO"  "$*"; }
log_ok()      { _log "$C_GREEN"  "OK"    "$*"; }
log_warn()    { _log "$C_YELLOW" "WARN"  "$*"; }
log_error()   { _log "$C_RED"    "ERROR" "$*"; }
log_debug()   { [[ "$DEBUG" == "1" ]] && _log "$C_MAGENTA" "DEBUG" "$*" || true; }
log_step()    { printf "\n${C_BOLD}${C_BLUE}━━━ %s ━━━${C_RESET}\n" "$*" >&2; }
die()         { log_error "$*"; exit 1; }

# مصيدة الأخطاء لطباعة السطر الذي فشل
trap 'die "فشل عند السطر $LINENO في ${FUNCNAME[0]:-main} (exit=$?)"' ERR

# ============================================================
# تحميل إعدادات الجهاز
# ============================================================
# load_env <file.env> [prefix]
load_env() {
  local file="$1" prefix="${2:-}"
  [[ -f "$file" ]] || die "ملف الإعدادات غير موجود: $file"
  # تحميل آمن: يقبل فقط KEY=VALUE ويتجاهل التعليقات/الأسطر الفارغة
  while IFS='=' read -r key value; do
    key="${key%%#*}"; key="$(echo "$key" | xargs)"
    [[ -z "$key" ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${value%#*}"; value="$(echo "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" | xargs)"
    printf -v "${prefix}${key}" '%s' "$value"
    export "${prefix}${key}"
  done < "$file"
  log_debug "تم تحميل $file (prefix=$prefix)"
}

load_source_env() { load_env "$CONFIG_DIR/source.env"; }
load_target_env() { load_env "$CONFIG_DIR/target.env"; }
load_all_env()    { load_source_env; load_target_env; }

# ============================================================
# فحوصات الأدوات والجذور
# ============================================================
require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "هذا السكربت يتطلب صلاحيات root (استخدم sudo أو تشغيل داخل حاوية)."
}

require_tools() {
  local missing=()
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then missing+=("$t"); fi
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  die "أدوات مفقودة: ${missing[*]}
شغّل أولاً: bash scripts/00_setup.sh"
}

# ============================================================
# عمليات الصور (sparse / ext4 / erofs)
# ============================================================
# is_sparse <file> — يكتشف صور Android sparse
is_sparse() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # السحر: 0x3a53 0xed26 للصور sparse
  local magic; magic="$(xxd -p -l 4 "$f" 2>/dev/null | tr -d '[:space:]')"
  [[ "$magic" == "3aff26ed" ]]
}

# rawize <sparse.img> <out.raw> — تحويل sparse إلى raw
rawize() {
  local in="$1" out="$2"
  require_tools simg2img
  if is_sparse "$in"; then
    log_info "تحويل sparse → raw: $(basename "$in")"
    simg2img "$in" "$out"
  else
    log_debug "الصورة raw أصلاً، نسخ مباشر: $(basename "$in")"
    cp "$in" "$out"
  fi
}

# sparsify <raw.img> <out.sparse.img> — تحويل raw إلى sparse
sparsify() {
  local in="$1" out="$2"
  require_tools img2simg
  log_info "تحويل raw → sparse: $(basename "$in")"
  img2simg "$in" "$out"
}

# detect_image_type <file> — يطبع ext4 | erofs | unknown
detect_image_type() {
  local f="$1"
  require_tools file
  local desc; desc="$(file -b "$f")"
  case "$desc" in
    *ext2*|*ext4*|*Ext2*) echo "ext4";;
    *erofs*|*EROFS*)      echo "erofs";;
    *)                    echo "unknown";;
  esac
}

# mount_rw <img> <mountpoint> — يركّب صورة قابلة للكتابة (ext4 loop)
mount_rw() {
  local img="$1" mp="$2"
  require_root
  mkdir -p "$mp"
  local type; type="$(detect_image_type "$img")"
  case "$type" in
    ext4)
      log_info "تركيب ext4 rw: $(basename "$img") → $mp"
      mount -o loop,rw "$img" "$mp"
      ;;
    erofs)
      # EROFS للقراءة فقط في النواة؛ نستخدم erofs-fuse ثم ننسخ لمجلد عمل.
      log_warn "EROFS للقراءة فقط — سيتم استخراجها بدل التركيب rw."
      extract_erofs "$img" "$mp"
      ;;
    *)
      die "نوع صورة غير معروف لـ $img: $type"
      ;;
  esac
}

# extract_erofs <img> <out_dir> — استخراج EROFS عبر dump.erofs
extract_erofs() {
  local img="$1" out="$2"
  require_tools dump.erofs
  mkdir -p "$out"
  log_info "استخراج EROFS: $(basename "$img") → $out"
  dump.erofs "$img" "$out"
}

# umount_clean <mountpoint> — تفكيك آمن
umount_clean() {
  local mp="$1"
  if mountpoint -q "$mp" 2>/dev/null; then
    sync
    umount -d "$mp" 2>/dev/null || umount -lf "$mp" || true
  fi
  # إذا كان مجلد عمل مستخرج (من EROFS) نتركه للمعالجة اللاحقة
}

# ============================================================
# أدوات الأقسام الديناميكية (super.img)
# ============================================================
# unpack_super <super.img> <out_dir> — فك super إلى أقسامه
unpack_super() {
  local super="$1" out="$2"
  require_tools lpunpack
  mkdir -p "$out"
  log_info "فك super.img → $out"
  lpunpack "$super" "$out"
}

# list_super_partitions <super.img>
list_super_partitions() {
  local super="$1"
  require_tools lpdump
  lpdump "$super" 2>/dev/null | awk '/Partition name:/ {print $3}' | tr -d "'"
}

# ============================================================
# أدوات عامة
# ============================================================
ensure_dirs() {
  for d in "$WORK_DIR" "$OUTPUT_DIR" "$DOWNLOAD_DIR"; do
    mkdir -p "$d"
  done
}

# hash_file <file> — sha256
hash_file() {
  require_tools sha256sum
  sha256sum "$1" | awk '{print $1}'
}

# git_info — معلومات النسخة للناتج
git_info() {
  if command -v git >/dev/null 2>&1 && git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$(git -C "$PROJECT_ROOT" rev-parse --short HEAD) $(date -u +%Y%m%d-%H%M)"
  else
    echo "nogit $(date -u +%Y%m%d-%H%M)"
  fi
}

# selfcheck — تحقق سريع من البيئة عند تحميل المكتبة
selfcheck() {
  ensure_dirs
  log_debug "common.sh loaded | PROJECT_ROOT=$PROJECT_ROOT"
}

selfcheck
