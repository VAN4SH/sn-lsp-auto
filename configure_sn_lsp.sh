#!/usr/bin/env bash
#==============================================================================
# configure_sn_lsp.sh — настройка Secret Net LSP без знания имён политик
#
#   sudo bash configure_sn_lsp.sh
#
# Пользователь выбирает действие словами («включить», «5 попыток»).
# Имена политик и формат snpolctl скрипт подставляет сам.
#==============================================================================

set -euo pipefail
export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:/usr/sbin:/usr/bin:${PATH}"

die() { echo "Ошибка: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash $0"; }
have_sn() { command -v snpolctl >/dev/null 2>&1 || die "Secret Net не установлен (нет snpolctl). Сначала установка, потом это меню."; }

pause() { echo; read -r -p "Enter — продолжить... " _; }
hr() { printf '%s\n' "────────────────────────────────────────────────"; }

header() {
  clear 2>/dev/null || true
  echo "╔════════════════════════════════════════════════════════╗"
  echo "║     Secret Net — настройка простыми словами           ║"
  echo "╚════════════════════════════════════════════════════════╝"
  echo "  компьютер: $(hostname)    ядро: $(uname -r)"
  echo
}

ask_yes() {
  local a
  read -r -p "$1 [Д/н]: " a
  a="${a:-д}"
  case "$a" in д|Д|y|Y|да|Да) return 0 ;; *) return 1 ;; esac
}

# Каталог настроек. Поля через |
# группа|ключ|плагин|политика|параметр|название|пояснение|тип|варианты
# тип bool — включить/выключить
# тип enum — варианты  значение:подпись , через ;
CATALOG='
login|auth|token_mgr|authentication|state|Механизм контроля входа|Пока он выключен, число ошибок и время блокировки только записаны: экран входа их не использует.|bool|
login|pwd|users|users|passwd_strength|Сложность пароля|При смене пароля система потребует достаточно сложный пароль.|bool|
login|deny|token_mgr|authentication|deny|Сколько ошибок до блокировки|После этого числа неверных паролей вход блокируется.|enum|3:3 попытки;5:5 попыток (обычно так);10:10 попыток
login|unlock|token_mgr|authentication|unlock_time|На сколько минут блокировать|Как долго нельзя войти после превышения числа ошибок.|enum|5:5 минут;15:15 минут;30:30 минут (обычно так);60:1 час
login|delay|token_mgr|authentication|lock_delay|Пауза между попытками входа|Дополнительная задержка. Если не уверены — оставьте 15.|enum|0:без паузы;15:15 (обычно так);60:60
login|last|token_mgr|authentication|last_log|Показывать последний вход|На экране входа видно, когда этой учёткой входили в прошлый раз.|bool|
integrity|aide|aide|aide|state|Контроль целостности|Следит, не изменились ли важные файлы без разрешения.|bool|
integrity|lock|system|system|system_lock|Блокировать компьютер при нарушении|Если контроль целостности увидит подмену, станция уйдёт в блокировку. На учебном стенде лучше не включать, пока не проверите остальное.|bool|
memory|ram|control|memory|mode|Затирать остатки в памяти|После работы программ стирает данные, оставшиеся в оперативной памяти.|bool|
logs|audit|service_mgr|services|snauditd|Журнал аудита|Записывает события безопасности.|bool|
logs|journal|service_mgr|services|snjournald|Журнал Secret Net|Ведёт собственный журнал продукта.|bool|
logs|trash|service_mgr|services|sntrashd|Безопасное удаление|Файлы затираются при удалении, а не просто помечаются свободными.|bool|
extra|usb|devices|devices_control|state|Контроль USB и устройств|Ограничивает подключение флешек и других устройств. Нужна лицензия на этот механизм.|bool|
extra|fw|firewall|firewall|state|Межсетевой экран|Сетевой экран Secret Net (ПМЭ). Нужны пакет ПМЭ и лицензия.|bool|
extra|aec|aec|aec|state|Запрет чужих программ|Запускается только разрешённое ПО. Включайте после того, как понятен список нужных программ.|bool|
'

group_title() {
  case "$1" in
    login) echo "Пароли и вход" ;;
    integrity) echo "Целостность файлов" ;;
    memory) echo "Память" ;;
    logs) echo "Журналы" ;;
    extra) echo "Устройства, сеть, запуск программ" ;;
    *) echo "$1" ;;
  esac
}

catalog_lines() {
  printf '%s\n' "$CATALOG" | sed '/^[[:space:]]*$/d'
}

# Текущее значение параметра, если snpolctl его показывает
read_current() {
  local plugin="$1" policy="$2" param="$3" blob val
  blob="$(snpolctl -l 2>/dev/null || true)"
  val="$(printf '%s\n' "$blob" | awk -v plugin="$plugin" -v policy="$policy" -v param="$param" '
    /^Плагин:/ { p = $2; pol = ""; next }
    /^[[:space:]]*Политика:/ { pol = $2; next }
    p == plugin && pol == policy {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      n = index(line, "=")
      if (n == 0) next
      name = substr(line, 1, n - 1)
      v = substr(line, n + 1)
      gsub(/[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (name == param) { print v; exit }
    }
  ')" || true
  printf '%s' "$val"
}

human_value() {
  local kind="$1" raw="$2" opts="$3" pair v label
  [[ -n "$raw" ]] || { printf '%s' "ещё не видно"; return; }
  if [[ "$kind" == "bool" ]]; then
    case "$raw" in
      1) printf '%s' "включено" ;;
      0) printf '%s' "выключено" ;;
      *) printf '%s' "$raw" ;;
    esac
    return
  fi
  IFS=';' read -ra pairs <<< "$opts"
  for pair in "${pairs[@]}"; do
    v="${pair%%:*}"
    label="${pair#*:}"
    if [[ "$v" == "$raw" ]]; then
      printf '%s' "$label"
      return
    fi
  done
  printf '%s' "$raw"
}

apply_spec() {
  local title="$1" plugin="$2" spec="$3" out rest policy param want now
  echo
  hr
  echo "$title"
  echo "Команда: snpolctl -p $plugin -c $spec"
  hr
  if ! out="$(snpolctl -p "$plugin" -c "$spec" 2>&1)"; then
    printf '%s\n' "$out"
    echo "Не применилось. Частые причины:"
    echo "  • нет лицензии на эту функцию;"
    echo "  • станция заблокирована — пункт «Лицензия», разблокировка;"
    echo "  • не установлен пакет (для сети это ПМЭ)."
    return 1
  fi
  printf '%s\n' "$out"
  policy="${spec%%,*}"
  rest="${spec#*,}"
  param="${rest%%,*}"
  want="${rest#*,}"
  now="$(read_current "$plugin" "$policy" "$param")"
  if [[ -n "$now" ]]; then
    echo "В списке политик сейчас: $now"
  fi
  if printf '%s\n' "$out" | grep -q "не будут применены"; then
    echo "Фраза «изменения не будут применены» — ответ Secret Net, а не ошибка меню."
    echo "Значение при этом записывается. На демо-лицензии ограничена работа части механизмов, не сама запись."
    echo "Блокировка по числу ошибок работает только если включён «Механизм контроля входа»."
  fi
}

# Разобрать строку каталога в переменные
parse_row() {
  IFS='|' read -r G KEY PLUGIN POLICY PARAM TITLE HINT KIND OPTS <<< "$1"
}

edit_row() {
  local row="$1"
  parse_row "$row"
  local cur human n=1 choice val label spec custom
  while true; do
    header
    echo "$(group_title "$G")"
    echo
    echo "$TITLE"
    echo "$HINT"
    echo
    cur="$(read_current "$PLUGIN" "$POLICY" "$PARAM")"
    human="$(human_value "$KIND" "$cur" "$OPTS")"
    echo "Сейчас: $human"
    hr
    if [[ "$KIND" == "bool" ]]; then
      echo "  1) Включить"
      echo "  2) Выключить"
      echo "  0) Назад"
      read -r -p "Выбор: " choice
      case "$choice" in
        1) val=1; label="включить" ;;
        2) val=0; label="выключить" ;;
        0) return 0 ;;
        *) continue ;;
      esac
    else
      n=1
      IFS=';' read -ra pairs <<< "$OPTS"
      for pair in "${pairs[@]}"; do
        printf '  %s) %s\n' "$n" "${pair#*:}"
        n=$((n + 1))
      done
      echo "  $n) Ввести своё число"
      echo "  0) Назад"
      read -r -p "Выбор: " choice
      [[ "$choice" == "0" ]] && return 0
      if [[ "$choice" == "$n" ]]; then
        read -r -p "Число: " custom
        [[ "$custom" =~ ^[0-9]+$ ]] || { echo "Нужно целое число."; pause; continue; }
        val="$custom"
        label="$custom"
      elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < n )); then
        pair="${pairs[$((choice - 1))]}"
        val="${pair%%:*}"
        label="${pair#*:}"
      else
        continue
      fi
    fi
    ask_yes "Поставить «$TITLE»: $label?" || continue
    spec="${POLICY},${PARAM},${val}"
    apply_spec "$TITLE → $label" "$PLUGIN" "$spec" || true
    pause
    return 0
  done
}

menu_group() {
  local group="$1" row
  while true; do
    header
    echo "$(group_title "$group")"
    echo "Выберите, что изменить. Названия политик вводить не нужно."
    hr
    local i=1 rows=()
    while IFS= read -r row; do
      parse_row "$row"
      [[ "$G" == "$group" ]] || continue
      rows+=("$row")
      cur="$(read_current "$PLUGIN" "$POLICY" "$PARAM")"
      human="$(human_value "$KIND" "$cur" "$OPTS")"
      printf '  %2d) %-42s сейчас: %s\n' "$i" "$TITLE" "$human"
      i=$((i + 1))
    done < <(catalog_lines)
    echo "   0) Назад"
    read -r -p "Номер: " choice
    [[ "$choice" == "0" ]] && return 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#rows[@]} )); then
      edit_row "${rows[$((choice - 1))]}"
    fi
  done
}

recommended_preview() {
  cat <<'EOF'
Будет включено:
  • механизм контроля входа (иначе блокировка пароля только записана)
  • сложный пароль
  • блокировка после 5 неверных попыток на 30 минут
  • пауза между попытками 15
  • показ последнего входа
  • контроль целостности файлов
  • затирание остатков в памяти
  • журнал аудита, журнал Secret Net, безопасное удаление

Блокировка всего компьютера при нарушении целостности НЕ включается.
Её можно включить отдельно в разделе «Целостность файлов».
USB, сетевой экран и запрет программ тоже не трогаем: для них часто
нужна отдельная лицензия.
EOF
}

apply_recommended() {
  local items=(
    "token_mgr|authentication,state,1|механизм контроля входа"
    "users|users,passwd_strength,1|Сложность пароля"
    "token_mgr|authentication,deny,5|5 ошибок до блокировки"
    "token_mgr|authentication,unlock_time,30|блокировка на 30 минут"
    "token_mgr|authentication,lock_delay,15|пауза 15"
    "token_mgr|authentication,last_log,1|показ последнего входа"
    "aide|aide,state,1|контроль целостности"
    "control|memory,mode,1|затирание памяти"
    "service_mgr|services,snauditd,1|аудит"
    "service_mgr|services,snjournald,1|журнал Secret Net"
    "service_mgr|services,sntrashd,1|безопасное удаление"
  )
  local ok=0 fail=0 line plugin spec title
  command -v snunblock >/dev/null 2>&1 && snunblock >/dev/null 2>&1 || true
  for line in "${items[@]}"; do
    IFS='|' read -r plugin spec title <<< "$line"
    printf '  %s ... ' "$title"
    if snpolctl -p "$plugin" -c "$spec" >/dev/null 2>&1; then
      echo "ок"
      ok=$((ok + 1))
    else
      echo "не применилось"
      fail=$((fail + 1))
    fi
  done
  echo
  echo "Применилось: $ok. Не применилось: $fail."
  [[ "$fail" -eq 0 ]] || echo "Если что-то не встало — проверьте лицензию (пункт меню «Лицензия»)."
}

menu_license() {
  while true; do
    header
    echo "Лицензия и разблокировка"
    echo "Демо-лицензия настройки записывает. Отдельные механизмы без своей лицензии могут не работать."
    hr
    echo "  1) Показать, какая лицензия сейчас"
    echo "  2) Поставить файл лицензии"
    echo "  3) Разблокировать станцию, если она «заперта»"
    echo "  0) Назад"
    read -r -p "Выбор: " c
    case "$c" in
      1)
        echo
        snlicensectl -s 2>&1 || echo "snlicensectl не ответил"
        pause
        ;;
      2)
        read -r -p "Полный путь к файлу .lic: " lic
        if [[ ! -f "$lic" ]]; then echo "Файл не найден: $lic"; pause; continue; fi
        command -v snunblock >/dev/null 2>&1 && snunblock >/dev/null 2>&1 || true
        echo
        if snlicensectl -c "$lic"; then echo "Лицензия установлена."; else echo "Не установилась."; fi
        snlicensectl -s 2>&1 || true
        pause
        ;;
      3)
        if command -v snunblock >/dev/null 2>&1; then
          snunblock && echo "Команда разблокировки выполнена." || echo "Не разблокировалось."
        else
          echo "Команда snunblock не найдена."
        fi
        pause
        ;;
      0) return 0 ;;
    esac
  done
}

menu_overview() {
  header
  echo "Что сейчас включено (простыми словами)"
  hr
  local row cur human
  while IFS= read -r row; do
    parse_row "$row"
    cur="$(read_current "$PLUGIN" "$POLICY" "$PARAM")"
    human="$(human_value "$KIND" "$cur" "$OPTS")"
    printf '  %-42s %s\n' "$TITLE" "$human"
  done < <(catalog_lines)
  echo
  echo "Лицензия:"
  snlicensectl -s 2>&1 | sed 's/^/  /' | head -n 20 || true
  pause
}

menu_services() {
  header
  echo "Службы Secret Net в Linux"
  hr
  systemctl is-active sn.service snkernel.service snstart.service 2>/dev/null || true
  echo
  systemctl --no-pager --type=service --all 2>/dev/null | grep -E 'sn' || true
  echo
  echo "Модули ядра:"
  lsmod 2>/dev/null | awk '/^sn/{print "  "$1}' || true
  echo
  if ask_yes "Перезапустить службы Secret Net?"; then
    systemctl restart snkernel.service sn.service snstart.service 2>&1 || true
    echo "Команда перезапуска отправлена."
  fi
  pause
}

main() {
  need_root
  have_sn
  while true; do
    header
    echo "Что сделать?"
    echo
    echo "  1) Включить обычный набор настроек"
    echo "  2) Пароли и вход"
    echo "  3) Целостность файлов"
    echo "  4) Память"
    echo "  5) Журналы"
    echo "  6) USB, сеть, запуск программ"
    echo "  7) Лицензия и разблокировка"
    echo "  8) Посмотреть, что сейчас включено"
    echo "  9) Службы Secret Net"
    echo "  0) Выход"
    echo
    read -r -p "Номер: " c
    case "$c" in
      1)
        header
        echo "Обычный набор для первой настройки"
        hr
        recommended_preview
        hr
        if ask_yes "Применить этот набор?"; then
          apply_recommended
          pause
        fi
        ;;
      2) menu_group login ;;
      3) menu_group integrity ;;
      4) menu_group memory ;;
      5) menu_group logs ;;
      6) menu_group extra ;;
      7) menu_license ;;
      8) menu_overview ;;
      9) menu_services ;;
      0) echo "Выход."; exit 0 ;;
    esac
  done
}

main "$@"
