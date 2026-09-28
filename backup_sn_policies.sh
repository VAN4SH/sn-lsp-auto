#!/usr/bin/env bash
#==============================================================================
# backup_sn_policies.sh — бэкап / сравнение / откат политик Secret Net LSP
#
#   sudo bash backup_sn_policies.sh backup
#   sudo bash backup_sn_policies.sh list
#   sudo bash backup_sn_policies.sh compare [DIR_A] [DIR_B]
#   sudo bash backup_sn_policies.sh restore DIR [--dry-run] [--yes]
#   sudo bash backup_sn_policies.sh show DIR
#
# Бэкапы по умолчанию: /var/lib/sn-lsp-autoinstall/policy-backups/<timestamp>/
#   snpolctl-l.txt     — полный дамп snpolctl -l
#   plugins/*.txt      — дамп каждого плагина snpolctl -p
#   apply.txt          — строки PLUGIN|политика,параметр,значение  (для отката)
#   meta.txt           — хост, ядро, время, версия пакета
#
# Откат применяет только apply.txt. Полный текстовый дамп -l нужен для сравнения
# глазами / diff; snpolctl не всегда умеет «залить снимок целиком».
#==============================================================================

set -euo pipefail
export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:/usr/sbin:/usr/bin:${PATH}"

BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/sn-lsp-autoinstall/policy-backups}"
KNOWN_PLUGINS="users token_mgr aide system control service_mgr devices firewall aec"

die() { echo "Ошибка: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash $0 …"; }
have_sn() {
  command -v snpolctl >/dev/null 2>&1 || die "Secret Net не установлен (нет snpolctl в PATH)."
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \?//'
  exit 0
}

list_plugins() {
  local found
  found="$(snpolctl -l 2>/dev/null | awk '
    /^[[:space:]]*[a-zA-Z][a-zA-Z0-9_]*[[:space:]]*$/ {print $1}
    /^Plugin:|^Плагин:|^plugin:/ {print $2}
  ' | sort -u)" || true
  printf '%s\n%s\n' $KNOWN_PLUGINS "$found" | awk 'NF' | sort -u
}

# Из текста snpolctl -p вытащить кандидаты spec: a,b,c
extract_specs_from_plugin_dump() {
  local plugin="$1" file="$2"
  # Формат policy,param,value уже в строке
  sed 's/\r$//' "$file" 2>/dev/null \
    | sed -E 's/^[[:space:]]*[0-9]+[.)][[:space:]]*//; s/^[[:space:]]*[-*][[:space:]]*//' \
    | grep -Eo '[a-zA-Z][a-zA-Z0-9_]*,[a-zA-Z][a-zA-Z0-9_]*,[a-zA-Z0-9_.+-]+' \
    | while IFS= read -r spec; do
        [[ -n "$spec" ]] && printf '%s|%s\n' "$plugin" "$spec"
      done
  # param = value  /  param: value → plugin,param,value
  sed 's/\r$//' "$file" 2>/dev/null \
    | grep -E '^[[:space:]]*[a-zA-Z][a-zA-Z0-9_]*[[:space:]]*[=:][[:space:]]*[a-zA-Z0-9_.+-]+[[:space:]]*$' \
    | sed -E 's/^[[:space:]]*([a-zA-Z][a-zA-Z0-9_]*)[[:space:]]*[=:][[:space:]]*([a-zA-Z0-9_.+-]+).*/\1|\2/' \
    | while IFS='|' read -r key val; do
        [[ -n "$key" && -n "$val" ]] && printf '%s|%s,%s,%s\n' "$plugin" "$plugin" "$key" "$val"
      done
}

cmd_backup() {
  local stamp dir pl
  stamp="$(date '+%Y-%m-%d_%H%M%S')"
  dir="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$dir/plugins"
  chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
  chmod 700 "$dir"

  {
    echo "host=$(hostname)"
    echo "date=$(date -Iseconds)"
    echo "kernel=$(uname -r)"
    echo "user=$(id -un)"
    command -v snlicensectl >/dev/null && snlicensectl -s 2>&1 | head -20 | sed 's/^/license: /' || true
    rpm -q secretnet 2>/dev/null | sed 's/^/pkg: /' || dpkg-query -W -f='pkg: ${Package} ${Version}\n' secretnet 2>/dev/null || true
  } > "$dir/meta.txt"

  echo "→ snpolctl -l …"
  snpolctl -l > "$dir/snpolctl-l.txt" 2>&1 || true

  : > "$dir/apply.txt"
  echo "→ плагины …"
  while IFS= read -r pl; do
    [[ -z "$pl" ]] && continue
    snpolctl -p "$pl" > "$dir/plugins/${pl}.txt" 2>&1 || {
      echo "(нет данных / ошибка)" > "$dir/plugins/${pl}.txt"
      continue
    }
    extract_specs_from_plugin_dump "$pl" "$dir/plugins/${pl}.txt" >> "$dir/apply.txt" || true
  done < <(list_plugins)

  # уникальные строки apply
  if [[ -s "$dir/apply.txt" ]]; then
    sort -u "$dir/apply.txt" -o "$dir/apply.txt"
  fi

  # известные ключи из полного -l
  if [[ -f "$dir/snpolctl-l.txt" ]]; then
    grep -Eo 'users,passwd_strength,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/users|/' >> "$dir/apply.txt" || true
    grep -Eo 'authentication,(deny|unlock_time|lock_delay|last_log),[0-9]+' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/token_mgr|/' >> "$dir/apply.txt" || true
    grep -Eo 'aide,state,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/aide|/' >> "$dir/apply.txt" || true
    grep -Eo 'system,system_lock,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/system|/' >> "$dir/apply.txt" || true
    grep -Eo 'memory,mode,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/control|/' >> "$dir/apply.txt" || true
    grep -Eo 'services,(snauditd|snjournald|sntrashd),[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/service_mgr|/' >> "$dir/apply.txt" || true
    grep -Eo 'devices_control,state,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/devices|/' >> "$dir/apply.txt" || true
    grep -Eo 'firewall,state,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/firewall|/' >> "$dir/apply.txt" || true
    grep -Eo 'aec,state,[01]' "$dir/snpolctl-l.txt" 2>/dev/null \
      | sed 's/^/aec|/' >> "$dir/apply.txt" || true
    sort -u "$dir/apply.txt" -o "$dir/apply.txt"
  fi

  local n
  n="$(grep -c . "$dir/apply.txt" 2>/dev/null || true)"
  n="${n:-0}"
  echo
  echo "Готово: $dir"
  echo "  snpolctl-l.txt + plugins/ + apply.txt ($n параметров для отката)"
  echo "Сравнение с текущим позже:  sudo bash $0 compare $dir"
  echo "Откат:                     sudo bash $0 restore $dir --dry-run"
}

cmd_list() {
  mkdir -p "$BACKUP_ROOT"
  local d
  shopt -s nullglob
  local dirs=("$BACKUP_ROOT"/*/)
  if [[ ${#dirs[@]} -eq 0 ]]; then
    echo "Бэкапов нет в $BACKUP_ROOT"
    echo "Сделайте: sudo bash $0 backup"
    return 0
  fi
  printf '%-22s  %5s  %s\n' "ИМЯ" "apply" "путь"
  for d in "${dirs[@]}"; do
    d="${d%/}"
    local n=0
    [[ -f "$d/apply.txt" ]] && n="$(grep -c . "$d/apply.txt" 2>/dev/null || true)"
    n="${n:-0}"
    printf '%-22s  %5s  %s\n' "$(basename "$d")" "$n" "$d"
  done
}

resolve_backup_dir() {
  local arg="${1:-}"
  [[ -n "$arg" ]] || die "Укажите каталог бэкапа или имя (см. list)"
  if [[ -d "$arg" ]]; then
    printf '%s\n' "$(cd "$arg" && pwd)"
    return 0
  fi
  if [[ -d "${BACKUP_ROOT}/${arg}" ]]; then
    printf '%s\n' "${BACKUP_ROOT}/${arg}"
    return 0
  fi
  die "Бэкап не найден: $arg"
}

live_dump_to_tmp() {
  local tmp
  tmp="$(mktemp -d /tmp/sn-pol-live.XXXXXX)"
  snpolctl -l > "$tmp/snpolctl-l.txt" 2>&1 || true
  printf '%s\n' "$tmp"
}

cmd_compare() {
  local a="${1:-}" b="${2:-}"
  local dir_a dir_b tmp=""
  [[ -n "$a" ]] || die "compare: укажите хотя бы один бэкап (второй = текущее состояние)"

  dir_a="$(resolve_backup_dir "$a")"
  if [[ -z "$b" ]]; then
    echo "Сравнение: $dir_a  ↔  ТЕКУЩЕЕ (live snpolctl -l)"
    tmp="$(live_dump_to_tmp)"
    dir_b="$tmp"
  else
    dir_b="$(resolve_backup_dir "$b")"
    echo "Сравнение: $dir_a  ↔  $dir_b"
  fi

  [[ -f "$dir_a/snpolctl-l.txt" ]] || die "Нет $dir_a/snpolctl-l.txt"
  [[ -f "$dir_b/snpolctl-l.txt" ]] || die "Нет $dir_b/snpolctl-l.txt"

  echo
  if diff -u "$dir_a/snpolctl-l.txt" "$dir_b/snpolctl-l.txt"; then
    echo
    echo "Различий в snpolctl -l нет."
  else
    echo
    echo "(конец diff; ненулевой код — есть отличия)"
  fi

  # сравнение apply.txt если оба есть
  if [[ -f "$dir_a/apply.txt" && -f "$dir_b/apply.txt" ]]; then
    echo
    echo "=== apply.txt (параметры для отката) ==="
    diff -u "$dir_a/apply.txt" "$dir_b/apply.txt" || true
  elif [[ -f "$dir_a/apply.txt" && -n "$tmp" ]]; then
    echo
    echo "Подсказка: в live нет apply.txt — смотрите diff snpolctl-l выше."
  fi

  [[ -n "$tmp" ]] && rm -rf "$tmp"
  return 0
}

cmd_show() {
  local dir
  dir="$(resolve_backup_dir "${1:-}")"
  echo "=== $dir ==="
  [[ -f "$dir/meta.txt" ]] && { echo "--- meta ---"; cat "$dir/meta.txt"; echo; }
  if [[ -f "$dir/apply.txt" ]]; then
    echo "--- apply.txt ($(grep -c . "$dir/apply.txt" 2>/dev/null || true) строк) ---"
    cat "$dir/apply.txt"
    echo
  fi
  echo "--- snpolctl-l.txt (первые 80 строк) ---"
  head -80 "$dir/snpolctl-l.txt" 2>/dev/null || true
}

cmd_restore() {
  local dir dry=0 yes=0 arg
  dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      --yes|-y)  yes=1; shift ;;
      -*) die "Неизвестный флаг: $1" ;;
      *)
        [[ -z "$dir" ]] && dir="$1" || die "Лишний аргумент: $1"
        shift
        ;;
    esac
  done
  [[ -n "$dir" ]] || die "restore: укажите каталог бэкапа"
  dir="$(resolve_backup_dir "$dir")"
  [[ -f "$dir/apply.txt" ]] || die "Нет apply.txt в $dir — откат невозможен (только сравнение по snpolctl-l.txt)"

  local n
  n="$(grep -c . "$dir/apply.txt" 2>/dev/null || true)"
  n="${n:-0}"
  [[ "$n" -gt 0 ]] || die "apply.txt пуст"

  echo "Бэкап: $dir"
  echo "Параметров к применению: $n"
  echo
  if [[ $dry -eq 1 ]]; then
    echo "[dry-run] Будут выполнены:"
    while IFS='|' read -r pl spec; do
      [[ -z "${pl:-}" || -z "${spec:-}" ]] && continue
      [[ "$pl" == \#* ]] && continue
      echo "  snpolctl -p $pl -c $spec"
    done < "$dir/apply.txt"
    echo
    echo "Без --dry-run:  sudo bash $0 restore $dir --yes"
    return 0
  fi

  if [[ $yes -ne 1 ]]; then
    read -r -p "Применить $n параметров из бэкапа? [д/Н]: " ans
    case "$ans" in д|Д|y|Y|да|Да) ;; *) echo "Отменено."; return 0 ;; esac
  fi

  command -v snunblock >/dev/null 2>&1 && snunblock 2>/dev/null || true

  local ok=0 fail=0
  while IFS='|' read -r pl spec; do
    [[ -z "${pl:-}" || -z "${spec:-}" ]] && continue
    [[ "$pl" == \#* ]] && continue
    echo -n "  $pl ← $spec … "
    if snpolctl -p "$pl" -c "$spec" >/dev/null 2>&1; then
      echo "OK"
      ok=$((ok + 1))
    else
      echo "FAIL"
      fail=$((fail + 1))
    fi
  done < "$dir/apply.txt"

  echo
  echo "Готово: OK=$ok  FAIL=$fail"
  [[ $fail -eq 0 ]] || echo "Часть параметров не применилась (лицензия / нет механизма / формат)."
}

main() {
  need_root
  have_sn
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    backup)  cmd_backup "$@" ;;
    list)    cmd_list "$@" ;;
    compare) cmd_compare "$@" ;;
    restore) cmd_restore "$@" ;;
    show)    cmd_show "$@" ;;
    -h|--help|help|"") usage ;;
    *) die "Неизвестная команда: $cmd (см. --help)" ;;
  esac
}

main "$@"
