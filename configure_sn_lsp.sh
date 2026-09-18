#!/usr/bin/env bash
#==============================================================================
# configure_sn_lsp.sh — понятное меню настройки Secret Net LSP
# Гибко: можно включать/выключать и задавать свои значения.
# Плюс раздел «Все настройки» — обход всех плагинов SN на этой системе.
#
#   sudo bash configure_sn_lsp.sh
#==============================================================================

set -euo pipefail
export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:/usr/sbin:/usr/bin:${PATH}"

die() { echo "Ошибка: $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash $0"; }
have_sn() {
  command -v snpolctl >/dev/null 2>&1 || \
    die "Secret Net не установлен (нет snpolctl)."
}

pause() { echo; read -r -p "Enter — назад в меню... " _; }
hr() { echo "────────────────────────────────────────────────"; }
say() { printf '%s\n' "$*"; }

header() {
  clear
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║         Secret Net — настройка (простое меню)         ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo "  $(hostname) | $(uname -r)"
  echo
}

ask_yn() {
  local p="$1" d="${2:-y}" a
  if [[ "$d" == "y" ]]; then read -r -p "$p [Д/н]: " a; a="${a:-д}"
  else read -r -p "$p [д/Н]: " a; a="${a:-н}"; fi
  case "$a" in д|Д|y|Y|да|Да) return 0 ;; *) return 1 ;; esac
}

ask_num() {
  local p="$1" def="$2" min="${3:-0}" max="${4:-999999}" v
  while true; do
    read -r -p "$p [$def]: " v
    v="${v:-$def}"
    [[ "$v" =~ ^[0-9]+$ ]] && (( v>=min && v<=max )) && { printf '%s' "$v"; return; }
    say "Нужно число от $min до $max."
  done
}

ask_str() {
  local p="$1" def="${2:-}" v
  if [[ -n "$def" ]]; then read -r -p "$p [$def]: " v; printf '%s' "${v:-$def}"
  else read -r -p "$p: " v; printf '%s' "$v"; fi
}

# Показать команду и выполнить
run() {
  local title="$1"; shift
  echo
  hr
  say "$title"
  say "Команда: $*"
  hr
  if "$@"; then say "Успешно."; else
    say "Не получилось (код $?). Возможные причины:"
    say "  • нет лицензии на эту функцию;"
    say "  • станция заблокирована — сначала «Разблокировать»;"
    say "  • пакет механизма не установлен (например ПМЭ)."
  fi
  pause
}

# snpolctl -c с понятным названием
setp() {
  local title="$1" plugin="$2" spec="$3"
  run "$title" snpolctl -p "$plugin" -c "$spec"
}

# Список имён плагинов (эвристика по выводу snpolctl)
list_plugins() {
  # Сначала известный набор + то, что найдём в -l
  local known="users token_mgr aide system control service_mgr devices firewall aec"
  local found
  found="$(snpolctl -l 2>/dev/null | awk '
    /^[[:space:]]*[a-zA-Z0-9_]+[[:space:]]*$/ {print $1}
    /^Plugin:|^Плагин:|^plugin:/ {print $2}
  ' | sort -u)" || true
  printf '%s\n%s\n' $known "$found" | awk 'NF' | sort -u
}

#==============================================================================
# 1. Обзор
#==============================================================================
menu_overview() {
  header
  say "Что сейчас с Secret Net"
  hr
  say ""
  say "Лицензия:"
  snlicensectl -s 2>&1 | sed 's/^/  /' || say "  (нет данных)"
  say ""
  say "Службы:"
  for s in sn.service snkernel.service snstart.service; do
    printf '  %-20s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo —)"
  done
  say ""
  say "Модули в ядре:"
  lsmod 2>/dev/null | awk '/^sn/{print "  "$1}' || say "  нет"
  if ! lsmod 2>/dev/null | grep -qE '^sn'; then say "  (пусто)"; fi
  say ""
  say "Ключевые параметры (если читаются):"
  snpolctl -l 2>/dev/null \
    | grep -iE 'passwd_strength|deny|unlock|lock_delay|last_log|aide|system_lock|memory|snaudit|snjournal|sntrash|devices_control|firewall|aec' \
    | sed 's/^/  /' | head -50 || say "  откройте «Все настройки» для полного списка"
  pause
}

#==============================================================================
# 2. Лицензия
#==============================================================================
menu_license() {
  while true; do
    header
    say "Лицензия и разблокировка"
    say "Без лицензии часть функций просто не включится."
    hr
    echo "  1) Статус лицензии"
    echo "  2) Установить файл лицензии (.lic)"
    echo "  3) Разблокировать станцию (если «LOCKED»)"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) run "Статус лицензии" snlicensectl -s ;;
      2)
        lic="$(ask_str "Путь к .lic")"
        [[ -f "$lic" ]] || { say "Файл не найден"; pause; continue; }
        command -v snunblock >/dev/null && snunblock 2>/dev/null || true
        run "Установка лицензии" snlicensectl -c "$lic"
        ;;
      3)
        if command -v snunblock >/dev/null; then run "Разблокировка" snunblock
        else say "snunblock не найден"; pause; fi
        ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 3. Пароли и вход
#==============================================================================
menu_login() {
  while true; do
    header
    cat <<'EOF'
Пароли и вход в систему
  • сложность пароля
  • сколько ошибок до блокировки
  • на сколько блокировать
  • показывать ли время последнего входа
EOF
    hr
    echo "  1) Сложность пароля — ВКЛ"
    echo "  2) Сложность пароля — ВЫКЛ"
    echo "  3) Настроить блокировку после ошибок ввода (свои числа)"
    echo "  4) Показ последнего входа — ВКЛ"
    echo "  5) Показ последнего входа — ВЫКЛ"
    echo "  6) Посмотреть текущие значения"
    echo "  7) Задать любой параметр users вручную"
    echo "  8) Задать любой параметр входа (token_mgr) вручную"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) setp "Сложность пароля ВКЛ" users "users,passwd_strength,1" ;;
      2) setp "Сложность пароля ВЫКЛ" users "users,passwd_strength,0" ;;
      3)
        say "Сколько неверных попыток до блокировки?"
        deny="$(ask_num "Попыток" 5 1 100)"
        say "На сколько минут блокировать?"
        unlock="$(ask_num "Минут" 30 1 10080)"
        say "Доп. задержка (обычно 15, можно не менять)"
        delay="$(ask_num "Задержка" 15 0 1000)"
        ask_yn "Применить $deny ошибок / $unlock мин?" y || continue
        snpolctl -p token_mgr -c "authentication,deny,$deny" && say "OK deny=$deny" || say "Ошибка deny"
        snpolctl -p token_mgr -c "authentication,unlock_time,$unlock" && say "OK unlock=$unlock" || say "Ошибка unlock"
        snpolctl -p token_mgr -c "authentication,lock_delay,$delay" && say "OK delay=$delay" || say "Ошибка delay"
        pause
        ;;
      4) setp "Показ последнего входа ВКЛ" token_mgr "authentication,last_log,1" ;;
      5) setp "Показ последнего входа ВЫКЛ" token_mgr "authentication,last_log,0" ;;
      6) echo; snpolctl -p users; echo; snpolctl -p token_mgr; pause ;;
      7)
        say "Формат: политика,параметр,значение"
        say "Пример: users,passwd_strength,1"
        spec="$(ask_str "Спецификация")"
        [[ -n "$spec" ]] && setp "users: $spec" users "$spec"
        ;;
      8)
        say "Пример: authentication,deny,5"
        spec="$(ask_str "Спецификация")"
        [[ -n "$spec" ]] && setp "token_mgr: $spec" token_mgr "$spec"
        ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 4. Целостность
#==============================================================================
menu_integrity() {
  while true; do
    header
    cat <<'EOF'
Контроль целостности
  Проверяет, не меняли ли важные файлы без разрешения.
  Можно автоматически блокировать компьютер при нарушении.
EOF
    hr
    echo "  1) Контроль целостности — ВКЛ"
    echo "  2) Контроль целостности — ВЫКЛ"
    echo "  3) Блокировать ПК при нарушении — ВКЛ"
    echo "  4) Блокировать ПК при нарушении — ВЫКЛ"
    echo "  5) Посмотреть настройки"
    echo "  6) Свой параметр aide"
    echo "  7) Свой параметр system"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) setp "КЦ ВКЛ" aide "aide,state,1" ;;
      2) setp "КЦ ВЫКЛ" aide "aide,state,0" ;;
      3) setp "Блокировка станции ВКЛ" system "system,system_lock,1" ;;
      4) setp "Блокировка станции ВЫКЛ" system "system,system_lock,0" ;;
      5) echo; snpolctl -p aide; echo; snpolctl -p system; pause ;;
      6) spec="$(ask_str "Пример aide,state,1")"; [[ -n "$spec" ]] && setp "aide" aide "$spec" ;;
      7) spec="$(ask_str "Пример system,system_lock,1")"; [[ -n "$spec" ]] && setp "system" system "$spec" ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 5. Память
#==============================================================================
menu_memory() {
  while true; do
    header
    cat <<'EOF'
Очистка остатков в памяти
  После работы программ в RAM могут оставаться данные.
  Затирание уменьшает риск их восстановления.
EOF
    hr
    echo "  1) Затирание памяти — ВКЛ"
    echo "  2) Затирание памяти — ВЫКЛ"
    echo "  3) Посмотреть"
    echo "  4) Свой параметр (control)"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) setp "Затирание памяти ВКЛ" control "memory,mode,1" ;;
      2) setp "Затирание памяти ВЫКЛ" control "memory,mode,0" ;;
      3) echo; snpolctl -p control; pause ;;
      4) spec="$(ask_str "Пример memory,mode,1")"; [[ -n "$spec" ]] && setp "control" control "$spec" ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 6. Журналы
#==============================================================================
menu_logs() {
  while true; do
    header
    cat <<'EOF'
Журналы и учёт действий
  • аудит событий безопасности
  • журнал Secret Net
  • безопасное удаление файлов
EOF
    hr
    echo "  1) Включить всё сразу (аудит + журнал + безопасное удаление)"
    echo "  2) Аудит — ВКЛ / 3) ВЫКЛ"
    echo "  4) Журнал — ВКЛ / 5) ВЫКЛ"
    echo "  6) Безопасное удаление — ВКЛ / 7) ВЫКЛ"
    echo "  8) Посмотреть настройки служб"
    echo "  9) Свой параметр service_mgr"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1)
        ask_yn "Включить все три службы?" y || continue
        snpolctl -p service_mgr -c services,snauditd,1 || true
        snpolctl -p service_mgr -c services,snjournald,1 || true
        snpolctl -p service_mgr -c services,sntrashd,1 || true
        say "Готово (что смогло включиться)."; pause
        ;;
      2) setp "Аудит ВКЛ" service_mgr "services,snauditd,1" ;;
      3) setp "Аудит ВЫКЛ" service_mgr "services,snauditd,0" ;;
      4) setp "Журнал ВКЛ" service_mgr "services,snjournald,1" ;;
      5) setp "Журнал ВЫКЛ" service_mgr "services,snjournald,0" ;;
      6) setp "Безопасное удаление ВКЛ" service_mgr "services,sntrashd,1" ;;
      7) setp "Безопасное удаление ВЫКЛ" service_mgr "services,sntrashd,0" ;;
      8) echo; snpolctl -p service_mgr; pause ;;
      9) spec="$(ask_str "Пример services,snauditd,1")"; [[ -n "$spec" ]] && setp "service_mgr" service_mgr "$spec" ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 7. Устройства / сеть / ЗПС
#==============================================================================
menu_extra() {
  while true; do
    header
    cat <<'EOF'
Дополнительно (часто нужна отдельная лицензия)
  • контроль устройств (USB и т.п.)
  • межсетевой экран (ПМЭ)
  • запрет запуска чужих программ (ЗПС)
EOF
    hr
    echo "  1) Контроль устройств ВКЛ    2) ВЫКЛ"
    echo "  3) Межсетевой экран ВКЛ      4) ВЫКЛ"
    echo "  5) ЗПС (только своё ПО) ВКЛ  6) ВЫКЛ"
    echo "  7) Посмотреть все три"
    echo "  8) Свой параметр devices / firewall / aec"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) setp "Контроль устройств ВКЛ" devices "devices_control,state,1" ;;
      2) setp "Контроль устройств ВЫКЛ" devices "devices_control,state,0" ;;
      3) setp "ПМЭ ВКЛ" firewall "firewall,state,1" ;;
      4) setp "ПМЭ ВЫКЛ" firewall "firewall,state,0" ;;
      5) setp "ЗПС ВКЛ" aec "aec,state,1" ;;
      6) setp "ЗПС ВЫКЛ" aec "aec,state,0" ;;
      7) echo; snpolctl -p devices; echo; snpolctl -p firewall; echo; snpolctl -p aec; pause ;;
      8)
        echo "  d) devices   f) firewall   a) aec"
        read -r -p "Плагин [d/f/a]: " w
        spec="$(ask_str "политика,параметр,значение")"
        case "$w" in
          d|D) setp "devices" devices "$spec" ;;
          f|F) setp "firewall" firewall "$spec" ;;
          a|A) setp "aec" aec "$spec" ;;
        esac
        ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 8. Все плагины (гибко, всё что есть в SN)
#==============================================================================
menu_all_plugins() {
  while true; do
    header
    say "Все разделы политик Secret Net на этой машине"
    say "Можно открыть любой и менять параметры гибко."
    hr
    mapfile -t plugs < <(list_plugins)
    local i=1
    for p in "${plugs[@]}"; do
      printf '  %2d) %s\n' "$i" "$p"
      ((i++)) || true
    done
    echo "   A) Показать ВСЕ политики разом (snpolctl -l)"
    echo "   S) Задать: плагин + политика,параметр,значение"
    echo "   0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      0) return ;;
      A|a) echo; snpolctl -l 2>&1 | less -R || snpolctl -l; pause ;;
      S|s)
        pl="$(ask_str "Имя плагина (например aide)")"
        spec="$(ask_str "Спецификация (например aide,state,1)")"
        [[ -n "$pl" && -n "$spec" ]] && setp "$pl ← $spec" "$pl" "$spec"
        ;;
      *)
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#plugs[@]} )); then
          local pl="${plugs[$((c-1))]}"
          while true; do
            header
            say "Плагин: $pl"
            hr
            snpolctl -p "$pl" 2>&1 | head -80
            hr
            echo "  1) Обновить вывод"
            echo "  2) Изменить параметр (политика,параметр,значение)"
            echo "  0) К списку плагинов"
            read -r -p "Выбор: " x
            case "$x" in
              1) continue ;;
              2)
                spec="$(ask_str "Например state,1 или aide,state,1")"
                # если пользователь дал 2 поля — дополним именем плагина как политику часто совпадает
                [[ -n "$spec" ]] || continue
                setp "$pl" "$pl" "$spec"
                ;;
              0) break ;;
            esac
          done
        fi
        ;;
    esac
  done
}

#==============================================================================
# 9. Службы ОС / модули / журналы утилит
#==============================================================================
menu_system() {
  while true; do
    header
    say "Службы Linux и утилиты Secret Net"
    hr
    echo "  1) Статус служб sn / snkernel / snstart"
    echo "  2) Перезапустить службы SN"
    echo "  3) Модули ядра (lsmod)"
    echo "  4) Справка snpolctl"
    echo "  5) Справка snlicensectl"
    echo "  6) Журнал snjrnl (если есть)"
    echo "  7) Выполнить любую команду вручную"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1) run "Статус служб" systemctl status sn.service snkernel.service snstart.service --no-pager ;;
      2)
        ask_yn "Перезапустить sn, snkernel, snstart?" y || continue
        systemctl restart snkernel.service sn.service snstart.service 2>&1 || true
        say "Готово."; pause
        ;;
      3) echo; lsmod | grep -E '^sn' || echo "нет sn*"; pause ;;
      4) snpolctl --help 2>&1 | less || snpolctl --help; pause ;;
      5) snlicensectl --help 2>&1 | less || snlicensectl --help; pause ;;
      6)
        if command -v snjrnl >/dev/null; then snjrnl --help 2>&1 | head -40; pause
        else say "snjrnl не найден"; pause; fi
        ;;
      7)
        cmd="$(ask_str "Команда")"
        [[ -n "$cmd" ]] || continue
        echo; bash -c "$cmd"; pause
        ;;
      0) return ;;
    esac
  done
}

#==============================================================================
# 10. Шаблон «быстро включить типовое»
#==============================================================================
menu_quick() {
  header
  cat <<'EOF'
Быстрый шаблон (по желанию)
Включит часто используемую базу:
  сложный пароль, блокировка после 5 ошибок (30 мин),
  контроль целостности + блокировка станции,
  затирание памяти, аудит/журнал/безопасное удаление.

Это не «единственно верная» схема — дальше всё можно
поменять пунктами меню точечно.
EOF
  hr
  ask_yn "Применить шаблон?" n || return
  command -v snunblock >/dev/null && snunblock 2>/dev/null || true
  snpolctl -p users -c users,passwd_strength,1 || true
  snpolctl -p token_mgr -c authentication,deny,5 || true
  snpolctl -p token_mgr -c authentication,unlock_time,30 || true
  snpolctl -p token_mgr -c authentication,lock_delay,15 || true
  snpolctl -p token_mgr -c authentication,last_log,1 || true
  snpolctl -p aide -c aide,state,1 || true
  snpolctl -p system -c system,system_lock,1 || true
  snpolctl -p control -c memory,mode,1 || true
  snpolctl -p service_mgr -c services,snauditd,1 || true
  snpolctl -p service_mgr -c services,snjournald,1 || true
  snpolctl -p service_mgr -c services,sntrashd,1 || true
  say "Шаблон отправлен. Проверьте пункт «Обзор»."; pause
}

menu_export() {
  local f="/root/sn-settings-$(date +%F-%H%M).txt"
  {
    echo "Secret Net dump $(date) host=$(hostname)"
    echo
    snlicensectl -s 2>&1 || true
    echo
    snpolctl -l 2>&1 || true
  } > "$f"
  say "Сохранено: $f"
  pause
}

#==============================================================================
main() {
  need_root
  have_sn
  while true; do
    header
    say "Выберите раздел настройки:"
    echo
    echo "  1) Обзор — что уже включено"
    echo "  2) Лицензия и разблокировка"
    echo "  3) Пароли и вход в систему"
    echo "  4) Контроль целостности файлов"
    echo "  5) Очистка памяти"
    echo "  6) Журналы и аудит"
    echo "  7) USB / сеть / запрет чужого ПО"
    echo "  8) Все настройки SN (любой плагин, гибко)"
    echo "  9) Службы Linux и утилиты SN"
    echo " 10) Быстрый шаблон типовых включений"
    echo " 11) Сохранить всё в файл"
    echo "  0) Выход"
    echo
    read -r -p "Номер: " c
    case "$c" in
      1) menu_overview ;;
      2) menu_license ;;
      3) menu_login ;;
      4) menu_integrity ;;
      5) menu_memory ;;
      6) menu_logs ;;
      7) menu_extra ;;
      8) menu_all_plugins ;;
      9) menu_system ;;
      10) menu_quick ;;
      11) menu_export ;;
      0) say "Выход."; exit 0 ;;
      *) say "Нет такого пункта"; pause ;;
    esac
  done
}

main "$@"
