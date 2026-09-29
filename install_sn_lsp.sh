#!/usr/bin/env bash
#==============================================================================
# install_sn_lsp.sh — автоустановка Secret Net LSP 1.12 (+ ПМЭ) на:
#   • Astra Linux CE 2.12
#   • РЕД ОС 8
#   • ALT Linux СП (c10f1)
#
# Что делает:
#   1) определяет ОС
#   2) находит пакеты SN / firewall в каталоге
#   3) ЕДИНСТВЕННЫЙ источник правды по ядрам — модули внутри пакета SN
#      (/lib/modules/<uname -r>/...). Список меняется с версией SN — хардкода нет.
#   4) если uname -r нет в пакете → сам подключает репо ОС / DVD / зеркала,
#      качает и ставит нужное ядро ИЗ матрицы пакета SN
#   5) ставит SN → reboot → ПМЭ → лицензия (политики — вручную под заказчика)
#
# Запуск (от root или через sudo):
#   sudo bash install_sn_lsp.sh --pkg-dir /path/to/packages --license /path/to.lic
#
# В --pkg-dir можно заранее положить kernel-*.rpm / linux-image-*.deb —
# скрипт подхватит их автоматически (офлайн-режим).
#
# После reboot снова запустите ТУ ЖЕ команду — скрипт продолжит с сохранённого этапа.
# Состояние: /var/lib/sn-lsp-autoinstall/state
#
# Опции:
#   --pkg-dir DIR       каталог с .deb/.rpm SN и firewall (обязательно)
#   --license FILE      файл .lic (опционально)
#   --skip-kernel       не менять ядро (если несовместимо — ошибка)
#   --skip-firewall     не ставить ПМЭ
#   --skip-repos        не трогать / не дописывать репозитории ОС
#   --no-reboot         не перезагружать (выйти с кодом 2, если reboot нужен)
#   --force-phase N     принудительно начать с этапа (0..5)
#   --dry-run           только показать план
#   -h|--help
#==============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/var/lib/sn-lsp-autoinstall"
STATE_FILE="${STATE_DIR}/state"
LOG_FILE="${STATE_DIR}/install.log"
MARKER_NEED_REBOOT="${STATE_DIR}/need_reboot"
KERNEL_CACHE_DIR="${STATE_DIR}/kernel-cache"

PKG_DIR=""
LICENSE_FILE=""
SKIP_KERNEL=0
SKIP_FIREWALL=0
SKIP_REPOS=0
NO_REBOOT=0
FORCE_PHASE=""
DRY_RUN=0
PKG_KERNELS=""
KERNEL_LOCAL_RPM=""   # путь к скачанному/найденному пакету ядра

#------------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите от root: sudo bash $SCRIPT_NAME ..."; }

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \?//'
  exit 0
}

#------------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pkg-dir)        PKG_DIR="${2:-}"; shift 2 ;;
      --license)        LICENSE_FILE="${2:-}"; shift 2 ;;
      --skip-kernel)    SKIP_KERNEL=1; shift ;;
      --skip-firewall)  SKIP_FIREWALL=1; shift ;;
      --skip-repos)     SKIP_REPOS=1; shift ;;
      --no-reboot)      NO_REBOOT=1; shift ;;
      --force-phase)    FORCE_PHASE="${2:-}"; shift 2 ;;
      --dry-run)        DRY_RUN=1; shift ;;
      -h|--help)        usage ;;
      *) die "Неизвестный аргумент: $1 (см. --help)" ;;
    esac
  done
  [[ -n "$PKG_DIR" ]] || die "Укажите --pkg-dir /путь/к/пакетам"
  [[ -d "$PKG_DIR" ]] || die "Каталог не найден: $PKG_DIR"
  PKG_DIR="$(cd "$PKG_DIR" && pwd)"
  if [[ -n "$LICENSE_FILE" ]]; then
    [[ -f "$LICENSE_FILE" ]] || die "Лицензия не найдена: $LICENSE_FILE"
    LICENSE_FILE="$(cd "$(dirname "$LICENSE_FILE")" && pwd)/$(basename "$LICENSE_FILE")"
  fi
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  touch "$LOG_FILE"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
}

save_state() {
  local phase="$1"
  cat > "$STATE_FILE" <<EOF
PHASE=$phase
OS_ID=${OS_ID:-}
PKG_DIR=$PKG_DIR
LICENSE_FILE=${LICENSE_FILE:-}
SN_PKG=${SN_PKG:-}
FW_PKG=${FW_PKG:-}
SKIP_KERNEL=$SKIP_KERNEL
SKIP_FIREWALL=$SKIP_FIREWALL
UPDATED_AT=$(date -Iseconds)
EOF
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 1
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  # CLI имеет приоритет, если передали снова
  return 0
}

do_reboot() {
  save_state "$1"
  touch "$MARKER_NEED_REBOOT"
  log "Требуется перезагрузка (этап → $1). После boot снова: sudo bash $SCRIPT_NAME --pkg-dir '$PKG_DIR' ${LICENSE_FILE:+--license '$LICENSE_FILE'}"
  if [[ $NO_REBOOT -eq 1 ]]; then
    log "---no-reboot: выходим с кодом 2"
    exit 2
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] reboot пропущен"
    exit 0
  fi
  sync
  sleep 2
  reboot
  exit 0
}

#------------------------------------------------------------------------------
detect_os() {
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  local id="${ID:-}" name="${NAME:-}" pretty="${PRETTY_NAME:-}"
  OS_ID=""
  case "$id" in
    astra) OS_ID="astra" ;;
    redos|red-os) OS_ID="redos" ;;
    altlinux|altlinuxsp|alt) OS_ID="alt" ;;
  esac
  if [[ -z "$OS_ID" ]]; then
    echo "$pretty $name $id" | grep -qi astra && OS_ID="astra"
    echo "$pretty $name $id" | grep -qiE 'ред.?ос|red.?os' && OS_ID="redos"
    echo "$pretty $name $id" | grep -qiE 'alt' && OS_ID="alt"
  fi
  [[ -n "$OS_ID" ]] || die "Неизвестная ОС: ID=$id NAME=$name. Поддержка: astra / redos / alt"
  log "ОС: $OS_ID ($pretty), ядро: $(uname -r)"
}

#------------------------------------------------------------------------------
find_packages() {
  local sn_pat fw_pat
  case "$OS_ID" in
    astra)
      sn_pat='sn-lsp_*astra*.deb'
      fw_pat='snlsp-firewall_*astra*.deb'
      ;;
    redos)
      sn_pat='sn-lsp*redos*.rpm'
      fw_pat='snlsp-firewall*red*.rpm'
      ;;
    alt)
      # предпочитаем c10f1
      sn_pat='sn-lsp*alt0.c10f1*.rpm'
      fw_pat='snlsp-firewall*alt0.c10f1*.rpm'
      ;;
  esac

  mapfile -t _sn < <(find "$PKG_DIR" -maxdepth 2 -type f -name "$sn_pat" 2>/dev/null | sort)
  mapfile -t _fw < <(find "$PKG_DIR" -maxdepth 2 -type f -name "$fw_pat" 2>/dev/null | sort)

  if [[ "$OS_ID" == "alt" && ${#_sn[@]} -eq 0 ]]; then
    mapfile -t _sn < <(find "$PKG_DIR" -maxdepth 2 -type f -name 'sn-lsp*alt*.rpm' | sort)
    mapfile -t _fw < <(find "$PKG_DIR" -maxdepth 2 -type f -name 'snlsp-firewall*alt*.rpm' | sort)
  fi

  [[ ${#_sn[@]} -ge 1 ]] || die "Не найден пакет SN в $PKG_DIR (шаблон: $sn_pat)"
  SN_PKG="${_sn[-1]}"
  if [[ $SKIP_FIREWALL -eq 0 ]]; then
    [[ ${#_fw[@]} -ge 1 ]] || die "Не найден пакет ПМЭ (firewall) в $PKG_DIR"
    FW_PKG="${_fw[-1]}"
  else
    FW_PKG=""
  fi
  log "Пакет SN: $SN_PKG"
  [[ -n "$FW_PKG" ]] && log "Пакет ПМЭ: $FW_PKG"
}

# Список версий ядер = каталоги /lib/modules/<ver> внутри пакета SN.
# Это и есть матрица совместимости конкретной сборки (2509, 334, …).
list_kernels_in_pkg() {
  local pkg="$1"
  local raw=""
  if [[ "$pkg" == *.deb ]]; then
    raw="$(dpkg-deb -c "$pkg" 2>/dev/null || true)"
  elif [[ "$pkg" == *.rpm ]]; then
    if command -v rpm >/dev/null 2>&1; then
      raw="$(rpm -qlp "$pkg" 2>/dev/null || true)"
    else
      raw="$(rpm2cpio "$pkg" 2>/dev/null | cpio -t 2>/dev/null || true)"
    fi
  else
    die "Неизвестный тип пакета: $pkg"
  fi
  printf '%s\n' "$raw" \
    | sed -n -e 's|.*/lib/modules/\([^/]*\)/.*|\1|p' \
             -e 's|^/*lib/modules/\([^/]*\)/.*|\1|p' \
             -e 's|.*/usr/lib/modules/\([^/]*\)/.*|\1|p' \
    | grep -E '^[0-9]+\.[0-9]+' \
    | grep -Ev '^(extra|weak-updates|debug)$' \
    | sort -u -V
}

load_kernels_from_sn_pkg() {
  PKG_KERNELS="$(list_kernels_in_pkg "$SN_PKG")"
  [[ -n "$PKG_KERNELS" ]] || die "В пакете SN не найдены модули /lib/modules/<ядро>/.
Пакет: $SN_PKG
Без этого списка нельзя проверить совместимость — возьмите корректный deb/rpm Secret Net."
  local n
  n="$(printf '%s\n' "$PKG_KERNELS" | grep -c . || true)"
  log "Поддерживаемые ядра ИЗ ПАКЕТА SN ($n шт., источник: $(basename "$SN_PKG")):"
  printf '%s\n' "$PKG_KERNELS" | sed 's/^/  • /' | tee -a "$LOG_FILE" >&2
  printf '%s\n' "$PKG_KERNELS" > "${STATE_DIR}/kernels-from-package.txt"
}

# Точное совпадение uname -r с записью в пакете (или пакетный kver — префикс uname).
kernel_supported() {
  local cur="$1"
  local k
  [[ -n "$PKG_KERNELS" ]] || return 1
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    [[ "$k" == "$cur" ]] && return 0
  done <<< "$PKG_KERNELS"
  return 1
}

# Уже стоит в /boot одно из ядер из пакета? (предпочитаем более новое)
boot_has_supported_kernel() {
  local k
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if [[ -e "/boot/vmlinuz-$k" ]]; then
      printf '%s\n' "$k"
      return 0
    fi
  done <<< "$(printf '%s\n' "$PKG_KERNELS" | sort -V -r)"
  return 1
}

# Модули PARSEC под целевое ядро (иначе: «init parsec module missing» и зависание)
astra_install_parsec_for_kernel() {
  local kver="$1" p found=0
  local candidates=(
    "parsec-linux-modules-${kver}"
    "linux-modules-parsec-${kver}"
    "astra-parsec-modules-${kver}"
  )

  if find "/lib/modules/${kver}" -iname '*parsec*' 2>/dev/null | grep -q .; then
    log "PARSEC уже есть в /lib/modules/${kver}"
    depmod "$kver" 2>/dev/null || true
    return 0
  fi

  for p in "${candidates[@]}"; do
    if apt-cache show "$p" &>/dev/null; then
      log "Ставим $p"
      if DEBIAN_FRONTEND=noninteractive apt-get install -y "$p"; then
        found=1
        break
      fi
    fi
  done

  if [[ $found -ne 1 ]]; then
    p="$(apt-cache search --names-only 'parsec' 2>/dev/null | grep -F "$kver" | awk '{print $1}' | head -1 || true)"
    if [[ -n "$p" ]]; then
      log "Ставим найденный пакет PARSEC: $p"
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" && found=1 || true
    fi
  fi

  depmod "$kver" 2>/dev/null || true

  if find "/lib/modules/${kver}" -iname '*parsec*' 2>/dev/null | grep -q .; then
    log "PARSEC modules OK для $kver"
    # в initrd тоже
    grep -qxF 'parsec' /etc/initramfs-tools/modules 2>/dev/null || echo 'parsec' >> /etc/initramfs-tools/modules
    return 0
  fi

  log "ERROR: нет модулей PARSEC для $kver — с этим ядром Astra не загрузится (parsec module missing)"
  return 1
}

# Astra/Debian: initrd с MODULES=most + драйверы диска с текущей системы
astra_prepare_initramfs_conf() {
  local conf="/etc/initramfs-tools/initramfs.conf"
  mkdir -p /etc/initramfs-tools
  touch "$conf"
  if grep -qE '^[[:space:]]*MODULES=' "$conf"; then
    sed -i -E 's/^[[:space:]]*MODULES=.*/MODULES=most/' "$conf"
  else
    echo 'MODULES=most' >> "$conf"
  fi
  if grep -qE '^[[:space:]]*COMPRESS=' "$conf"; then
    sed -i -E 's/^[[:space:]]*COMPRESS=.*/COMPRESS=gzip/' "$conf"
  else
    echo 'COMPRESS=gzip' >> "$conf"
  fi
}

# Явно кладём модули диска/ФС в initrd (иначе splash «висит» или panic root fs)
astra_seed_initramfs_modules() {
  local f="/etc/initramfs-tools/modules" m root_fs
  touch "$f"
  for m in \
    ahci sd_mod sr_mod ata_piix libata \
    virtio_blk virtio_pci virtio_scsi virtio_net virtio_mmio \
    nvme nvme_core usb_storage uas \
    ext4 xfs btrfs jfs \
    dm_mod dm_mirror dm_snapshot linear \
    crc32c crc32c_generic overlay squashfs \
    parsec
  do
    grep -qxF "$m" "$f" 2>/dev/null || echo "$m" >> "$f"
  done
  # что реально загружено сейчас под root
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    grep -qxF "$m" "$f" 2>/dev/null || echo "$m" >> "$f"
  done < <(lsmod 2>/dev/null | awk 'NR>1 {print $1}' | grep -iE '^(ahci|sd_|sr_|ata_|libata|virtio|nvme|ext4|xfs|btrfs|jfs|dm_|crc32|scsi|megaraid|mpt|uas|usb_storage)' || true)
  root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
  if [[ -n "$root_fs" ]]; then
    grep -qxF "$root_fs" "$f" 2>/dev/null || echo "$root_fs" >> "$f"
  fi
  log "initramfs modules seed: $(wc -l < "$f") строк"
}

astra_rebuild_initrd() {
  local kver="$1" sz
  astra_prepare_initramfs_conf
  astra_seed_initramfs_modules
  [[ -e "/boot/vmlinuz-$kver" ]] || { log "ERROR: нет /boot/vmlinuz-$kver"; return 1; }

  if [[ ! -f "/boot/config-$kver" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$kver" 2>/dev/null || true
    [[ -f "/usr/src/linux-headers-$kver/.config" ]] && \
      cp -a "/usr/src/linux-headers-$kver/.config" "/boot/config-$kver"
  fi

  log "Пересборка initrd для $kver (MODULES=most + disk modules)"
  update-initramfs -d -k "$kver" 2>/dev/null || true
  if ! update-initramfs -c -k "$kver" 2>&1; then
    update-initramfs -u -k "$kver" 2>&1 || { log "ERROR: update-initramfs не удалось"; return 1; }
  fi
  [[ -f "/boot/initrd.img-$kver" ]] || { log "ERROR: нет /boot/initrd.img-$kver"; return 1; }

  sz="$(stat -c%s "/boot/initrd.img-$kver" 2>/dev/null || echo 0)"
  log "initrd размер: $sz байт"
  if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz < 4000000 )); then
    log "ERROR: initrd подозрительно маленький — root fs при загрузке скорее всего не смонтируется"
    return 1
  fi
  return 0
}

# Выставить GRUB default на конкретное ядро; убрать quiet/splash (иначе «висит» на логотипе)
astra_set_grub_default() {
  local kver="$1"
  local grub_cfg entry id submenu_line path line cmdline

  mkdir -p /etc/default/grub.d
  if [[ -f /etc/default/grub ]]; then
    if grep -qE '^[[:space:]]*GRUB_DEFAULT=' /etc/default/grub; then
      sed -i -E 's/^[[:space:]]*GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
      echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
  fi

  cmdline=""
  if [[ -f /etc/default/grub ]]; then
    # shellcheck disable=SC1091
    cmdline="$(. /etc/default/grub 2>/dev/null; printf '%s' "${GRUB_CMDLINE_LINUX_DEFAULT:-}")"
  fi
  # убрать quiet/splash — зависание на splash скрывает причину
  cmdline="$(printf '%s' "$cmdline" | sed -E 's/(^|[[:space:]])quiet($|[[:space:]])/ /g; s/(^|[[:space:]])splash($|[[:space:]])/ /g' | xargs)"
  case " $cmdline " in
    *" plymouth.enable=0 "*) ;;
    *) cmdline="${cmdline:+$cmdline }plymouth.enable=0" ;;
  esac
  # Astra MAC: без max_ilev часто ломается загрузка/уровни целостности
  case " $cmdline " in
    *" parsec.max_ilev="*) ;;
    *) cmdline="${cmdline:+$cmdline }parsec.max_ilev=63" ;;
  esac

  cat > /etc/default/grub.d/99-sn-auto-kernel.cfg <<EOF
# install_sn_lsp.sh — ядро под SN, без тихого splash
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=true
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX_DEFAULT="${cmdline}"
EOF

  update-grub 2>/dev/null || true

  grub_cfg=""
  for grub_cfg in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
    [[ -f "$grub_cfg" ]] && break
  done
  [[ -f "$grub_cfg" ]] || { log "WARN: нет grub.cfg"; return 0; }

  line="$(grep -E "menuentry .*${kver}" "$grub_cfg" | head -n1 || true)"
  id="$(printf '%s\n' "$line" | sed -n "s/.*menuentry_id_option[[:space:]]*'\([^']*\)'.*/\1/p")"
  [[ -z "$id" ]] && id="$(printf '%s\n' "$line" | sed -n "s/.*\$menuentry_id_option[[:space:]]*'\([^']*\)'.*/\1/p")"
  entry="$(printf '%s\n' "$line" | sed -n "s/^[[:space:]]*menuentry[[:space:]]*'\([^']*\)'.*/\1/p")"

  submenu_line="$(awk -v k="$kver" '
    /^[[:space:]]*submenu / { last=$0; next }
    /menuentry / && index($0, k) { print last; exit }
  ' "$grub_cfg" || true)"
  path=""
  if [[ -n "$submenu_line" && -n "$id" ]]; then
    local sid
    sid="$(printf '%s\n' "$submenu_line" | sed -n "s/.*menuentry_id_option[[:space:]]*'\([^']*\)'.*/\1/p")"
    [[ -z "$sid" ]] && sid="$(printf '%s\n' "$submenu_line" | sed -n "s/.*\$menuentry_id_option[[:space:]]*'\([^']*\)'.*/\1/p")"
    [[ -n "$sid" ]] && path="${sid}>${id}"
  fi
  [[ -z "$path" && -n "$id" ]] && path="$id"
  [[ -z "$path" && -n "$entry" ]] && path="$entry"

  if command -v grub-editenv >/dev/null 2>&1; then
    grub-editenv /boot/grub/grubenv create 2>/dev/null || \
      grub-editenv /boot/grub2/grubenv create 2>/dev/null || true
  fi

  if [[ -n "$path" ]] && command -v grub-set-default >/dev/null 2>&1; then
    log "GRUB default → $path"
    grub-set-default "$path" 2>/dev/null || {
      [[ -n "$entry" ]] && grub-set-default "$entry" 2>/dev/null || true
    }
  else
    log "WARN: не нашли menuentry для $kver"
  fi

  log "grubenv: $(grub-editenv list 2>/dev/null || echo "(нет)")"
  log "cmdline: ${cmdline}"
}

#------------------------------------------------------------------------------
# Репозитории ОС + офлайн/зеркало для ядер из матрицы SN
#------------------------------------------------------------------------------
http_get() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 15 --max-time 600 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" --timeout=30 "$url"
  else
    return 1
  fi
}

http_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsI --connect-timeout 10 --max-time 20 "$url" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=15 "$url" 2>/dev/null
  else
    return 1
  fi
}

ensure_repos_redos() {
  [[ $SKIP_REPOS -eq 1 ]] && return 0
  log "РЕД ОС: проверка/подключение репозиториев"
  mkdir -p /etc/yum.repos.d

  # Включить уже существующие redos-репозитории
  local f
  for f in /etc/yum.repos.d/*.repo; do
    [[ -f "$f" ]] || continue
    sed -i 's/^enabled=0/enabled=1/g' "$f" 2>/dev/null || true
  done

  # Гарантированные зеркала (os/updates/extras/kernel) — если штатные пустые/битые
  if [[ ! -f /etc/yum.repos.d/sn-auto-redos-mirrors.repo ]]; then
    cat > /etc/yum.repos.d/sn-auto-redos-mirrors.repo <<'EOF'
[sn-auto-redos-os]
name=SN-auto REDOS 8 os (yandex)
baseurl=https://mirror.yandex.ru/redos/8.0/$basearch/os/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[sn-auto-redos-updates]
name=SN-auto REDOS 8 updates (yandex)
baseurl=https://mirror.yandex.ru/redos/8.0/$basearch/updates/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[sn-auto-redos-extras]
name=SN-auto REDOS 8 extras (yandex)
baseurl=https://mirror.yandex.ru/redos/8.0/$basearch/extras/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[sn-auto-redos-kernel]
name=SN-auto REDOS 8 kernel (yandex)
baseurl=https://mirror.yandex.ru/redos/8.0/$basearch/kernel/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[sn-auto-redos-os-rs]
name=SN-auto REDOS 8 os (red-soft)
baseurl=https://repo.red-soft.ru/redos/8.0/$basearch/os/
enabled=1
gpgcheck=0
skip_if_unavailable=1

[sn-auto-redos-updates-rs]
name=SN-auto REDOS 8 updates (red-soft)
baseurl=https://repo.red-soft.ru/redos/8.0/$basearch/updates/
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
    log "Записан /etc/yum.repos.d/sn-auto-redos-mirrors.repo"
  fi

  # Установочный DVD / ISO — если примонтирован или есть /dev/sr0
  local mnt="/mnt/sn-auto-dvd"
  if [[ ! -d /mnt/sn-auto-dvd-repo ]] && [[ -b /dev/sr0 || -b /dev/cdrom ]]; then
    mkdir -p "$mnt"
    local dev="/dev/sr0"
    [[ -b /dev/cdrom ]] && dev="/dev/cdrom"
    if mount "$dev" "$mnt" 2>/dev/null || mount -o ro "$dev" "$mnt" 2>/dev/null; then
      if [[ -d "$mnt/repodata" || -d "$mnt/BaseOS" || -d "$mnt/Packages" || -f "$mnt/.treeinfo" ]]; then
        log "Обнаружен установочный носитель на $dev — подключаем как локальный репо"
        cat > /etc/yum.repos.d/sn-auto-dvd.repo <<EOF
[sn-auto-dvd]
name=SN-auto install media
baseurl=file://$mnt
enabled=1
gpgcheck=0
EOF
        # Иногда Packages лежат в подкаталоге
        if [[ -d "$mnt/Packages" && ! -d "$mnt/repodata" ]]; then
          # file:// к каталогу с rpm без repodata — dnf не съест; скачаем нужные rpm напрямую ниже
          log "DVD смонтирован ($mnt), реподаты может не быть — будем искать rpm по имени"
        fi
      fi
    fi
  fi

  dnf clean metadata -y 2>/dev/null || true
  dnf makecache -y 2>/dev/null || log "WARN: dnf makecache не полностью успешен (сеть?) — попробуем зеркала/офлайн"
}

ensure_repos_astra() {
  [[ $SKIP_REPOS -eq 1 ]] && return 0
  log "Astra: проверка/подключение репозиториев apt"

  mkdir -p /etc/apt/sources.list.d

  # Версия: из пакета SN → os-release / astra_version
  local edition="ce212"  # ce212 | se17 | se18
  if [[ "${SN_PKG:-}" == *astra1.7* || "${SN_PKG:-}" == *astra1_7* ]]; then
    edition="se17"
  elif [[ "${SN_PKG:-}" == *astra1.8* || "${SN_PKG:-}" == *astra1_8* ]]; then
    edition="se18"
  elif [[ "${SN_PKG:-}" == *astra2.12* || "${SN_PKG:-}" == *astra2_12* ]]; then
    edition="ce212"
  else
    local ver=""
    ver="$(cat /etc/astra_version 2>/dev/null || true)"
    [[ -z "$ver" ]] && ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
    case "$ver" in
      1.7*|1_7*) edition="se17" ;;
      1.8*|1_8*) edition="se18" ;;
      2.12*|2_12*|orel*) edition="ce212" ;;
    esac
    # PRETTY_NAME подсказка
    if grep -qi 'Special Edition' /etc/os-release 2>/dev/null; then
      grep -qE '1\.8' /etc/os-release 2>/dev/null && edition="se18"
      grep -qE '1\.7' /etc/os-release 2>/dev/null && edition="se17"
    fi
  fi
  log "Astra edition для репозиториев: $edition"

  # cdrom: без диска ломает apt update — комментируем
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*deb[[:space:]]+cdrom:' "$f" 2>/dev/null; then
      cp -a "$f" "${f}.bak-sn-auto" 2>/dev/null || true
      sed -i -E 's/^([[:space:]]*)deb([[:space:]]+cdrom:)/\1# deb\2/' "$f"
      log "Закомментирован deb cdrom: в $f"
    fi
  done

  # Живые http(s) источники (не cdrom, не комментарии)
  local live=0
  live="$(grep -hE '^[[:space:]]*deb(-src)?[[:space:]]+' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
    | grep -v sn-auto-astra \
    | grep -vE 'cdrom:|^[[:space:]]*#' \
    | grep -cE 'https?://' || true)"
  live="${live:-0}"

  # HTTPS для зеркал Astra
  DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https ca-certificates 2>/dev/null || true

  write_astra_sources() {
    local host="$1"
    case "$edition" in
      ce212)
        cat > /etc/apt/sources.list.d/sn-auto-astra.list <<EOF
# Auto by install_sn_lsp.sh — Astra CE 2.12 (Orel), host=$host
deb https://${host}/astra/stable/2.12_x86-64/repository/ orel main contrib non-free
EOF
        ;;
      se17)
        cat > /etc/apt/sources.list.d/sn-auto-astra.list <<EOF
# Auto by install_sn_lsp.sh — Astra SE 1.7, host=$host
deb https://${host}/astra/stable/1.7_x86-64/repository-main/ 1.7_x86-64 main contrib non-free
deb https://${host}/astra/stable/1.7_x86-64/repository-update/ 1.7_x86-64 main contrib non-free
deb https://${host}/astra/stable/1.7_x86-64/repository-base/ 1.7_x86-64 main contrib non-free
deb https://${host}/astra/stable/1.7_x86-64/repository-extended/ 1.7_x86-64 main contrib non-free
EOF
        ;;
      se18)
        cat > /etc/apt/sources.list.d/sn-auto-astra.list <<EOF
# Auto by install_sn_lsp.sh — Astra SE 1.8, host=$host
deb https://${host}/astra/stable/1.8_x86-64/repository-main/ 1.8_x86-64 main contrib non-free
deb https://${host}/astra/stable/1.8_x86-64/repository-extended/ 1.8_x86-64 main contrib non-free
EOF
        ;;
    esac
  }

  astra_apt_ok() {
    local logf=/tmp/sn-apt-update-astra.log
    apt-get update >"$logf" 2>&1
    local rc=$?
    tail -15 "$logf" | sed 's/^/  /' || true
    if grep -qiE 'could not be read|Malformed|NO_PUBKEY' "$logf"; then
      # NO_PUBKEY часто всё же даёт частичный индекс — не сразу fail
      :
    fi
    if [[ $rc -ne 0 ]] && ! grep -qiE 'Get:|Hit:|Fetched' "$logf"; then
      return 1
    fi
    # Проверка что deps SN видны (типичные для astra2.12)
    if apt-cache show libmhash2 &>/dev/null || apt-cache show sudo &>/dev/null; then
      return 0
    fi
    return 1
  }

  local need_write=0
  if [[ "$live" -eq 0 ]]; then
    log "Сетевых deb-источников нет (пусто / примеры / только cdrom) — подключим зеркала"
    need_write=1
  elif ! apt-get update >/tmp/sn-apt-update-astra.log 2>&1; then
    log "apt-get update с текущими sources неуспешен — добавим зеркала Astra"
    need_write=1
  elif ! apt-cache show libmhash2 &>/dev/null && ! apt-cache show sudo &>/dev/null; then
    log "Текущие репо не отдают базовые пакеты — добавим зеркала Astra"
    need_write=1
  else
    log "Живых сетевых источников: $live — базовые пакеты уже видны"
  fi

  if [[ $need_write -eq 1 ]]; then
    local hosts=(
      "dl.astralinux.ru"
      "download.astralinux.ru"
    )
    local h ok=0
    for h in "${hosts[@]}"; do
      log "Пробуем зеркало Astra: $h ($edition)"
      write_astra_sources "$h"
      if astra_apt_ok; then
        log "Репозиторий Astra OK: $h"
        ok=1
        break
      fi
    done
    if [[ $ok -ne 1 ]]; then
      log "WARN: зеркала не подтвердили пакеты — пишем multi-host list"
      case "$edition" in
        ce212)
          cat > /etc/apt/sources.list.d/sn-auto-astra.list <<'EOF'
# Auto by install_sn_lsp.sh — Astra CE 2.12 multi-host
deb https://dl.astralinux.ru/astra/stable/2.12_x86-64/repository/ orel main contrib non-free
deb https://download.astralinux.ru/astra/stable/2.12_x86-64/repository/ orel main contrib non-free
EOF
          ;;
        se17)
          cat > /etc/apt/sources.list.d/sn-auto-astra.list <<'EOF'
# Auto by install_sn_lsp.sh — Astra SE 1.7 multi-host
deb https://dl.astralinux.ru/astra/stable/1.7_x86-64/repository-main/ 1.7_x86-64 main contrib non-free
deb https://dl.astralinux.ru/astra/stable/1.7_x86-64/repository-update/ 1.7_x86-64 main contrib non-free
deb https://dl.astralinux.ru/astra/stable/1.7_x86-64/repository-base/ 1.7_x86-64 main contrib non-free
deb https://dl.astralinux.ru/astra/stable/1.7_x86-64/repository-extended/ 1.7_x86-64 main contrib non-free
deb https://download.astralinux.ru/astra/stable/1.7_x86-64/repository-main/ 1.7_x86-64 main contrib non-free
deb https://download.astralinux.ru/astra/stable/1.7_x86-64/repository-base/ 1.7_x86-64 main contrib non-free
EOF
          ;;
        se18)
          cat > /etc/apt/sources.list.d/sn-auto-astra.list <<'EOF'
# Auto by install_sn_lsp.sh — Astra SE 1.8 multi-host
deb https://dl.astralinux.ru/astra/stable/1.8_x86-64/repository-main/ 1.8_x86-64 main contrib non-free
deb https://dl.astralinux.ru/astra/stable/1.8_x86-64/repository-extended/ 1.8_x86-64 main contrib non-free
deb https://download.astralinux.ru/astra/stable/1.8_x86-64/repository-main/ 1.8_x86-64 main contrib non-free
EOF
          ;;
      esac
      apt-get update 2>&1 | tail -12 || true
    fi
  fi

  log "Итоговый sn-auto-astra.list (если есть):"
  [[ -f /etc/apt/sources.list.d/sn-auto-astra.list ]] && sed 's/^/  /' /etc/apt/sources.list.d/sn-auto-astra.list || log "  (используются штатные sources)"
}

ensure_repos_alt() {
  [[ $SKIP_REPOS -eq 1 ]] && return 0
  log "ALT: настройка репозиториев для зависимостей SN"

  # Ветка из имени пакета SN: alt0.c10f1 → c10f1
  local branch="c10f1"
  if [[ "${SN_PKG:-}" == *c10f2* ]]; then
    branch="c10f2"
  elif [[ "${SN_PKG:-}" == *c10f1* ]]; then
    branch="c10f1"
  elif [[ "${SN_PKG:-}" == *c9f2* ]]; then
    branch="c9f2"
  elif [[ "${SN_PKG:-}" == *c9f1* ]]; then
    branch="c9f1"
  fi
  log "ALT ветка репозитория: $branch (по пакету SN)"

  mkdir -p /etc/apt/sources.list.d

  # На ALT SP vendor ID вроде [alt]/[cert8] часто НЕ заведены в /etc/apt/vendors.list.d
  # → apt падает: «Unknown vendor ID 'alt'» и не читает sources вообще.
  # Снимаем теги во всех list (с бэкапом), оставляем сами URL.
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*rpm[[:space:]]+\[[^]]+\]' "$f" 2>/dev/null; then
      cp -a "$f" "${f}.bak-sn-auto" 2>/dev/null || true
      sed -i -E 's/^([[:space:]]*rpm)[[:space:]]+\[[^]]+\]/\1/' "$f"
      log "Сняты vendor-теги [..] в $f (бэкап .bak-sn-auto)"
    fi
  done

  # Сколько «живых» rpm-строк уже есть (не комментарии)
  local live=0
  live="$(grep -hE '^[[:space:]]*rpm([[:space:]]|$)' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
    | grep -v sn-auto-alt \
    | grep -vcE '^[[:space:]]*#' || true)"
  live="${live:-0}"
  if [[ "$live" -eq 0 ]]; then
    log "В sources.list пусто / одни примеры — подключим зеркала сами"
  else
    log "Живых rpm-источников (кроме sn-auto): $live — добавим рабочие зеркала для deps"
  fi

  # Порядок: Яндекс → ftp.altlinux → download → update.altsp
  local mirrors=(
    "http://mirror.yandex.ru/altlinux"
    "http://ftp.altlinux.org/pub/distributions/ALTLinux"
    "http://download.altlinux.org/pub/distributions/ALTLinux"
    "http://update.altsp.su/pub/distributions/ALTLinux"
  )

  alt_apt_update_ok() {
    local logf=/tmp/sn-apt-update.log
    apt-get update >"$logf" 2>&1
    local rc=$?
    tail -12 "$logf" | sed 's/^/  /' || true
    if grep -qiE 'Unknown vendor|could not be read' "$logf"; then
      return 1
    fi
    # полный провал всех зеркал
    if [[ $rc -ne 0 ]] && ! grep -qiE 'Get:|Hit:|Fetched' "$logf"; then
      return 1
    fi
    return 0
  }

  write_alt_sources() {
    local base="$1"
    cat > /etc/apt/sources.list.d/sn-auto-alt.list <<EOF
# Auto by install_sn_lsp.sh — Secret Net deps ($branch), без [vendor]
rpm ${base} ${branch}/branch/x86_64 classic
rpm ${base} ${branch}/branch/x86_64-i586 classic
rpm ${base} ${branch}/branch/noarch classic
EOF
    if [[ "$branch" == c10f* || "$branch" == c9f* ]]; then
      cat >> /etc/apt/sources.list.d/sn-auto-alt.list <<EOF
rpm ${base} ${branch}/branch/x86_64 classic gostcrypto
rpm ${base} ${branch}/branch/noarch classic gostcrypto
EOF
    fi
  }

  write_alt_sources_legacy() {
    local base="$1"
    cat > /etc/apt/sources.list.d/sn-auto-alt.list <<EOF
# Auto by install_sn_lsp.sh — legacy path ($branch)
rpm ${base}/${branch}/branch x86_64 classic
rpm ${base}/${branch}/branch x86_64-i586 classic
rpm ${base}/${branch}/branch noarch classic
EOF
  }

  local m ok=0
  for m in "${mirrors[@]}"; do
    log "Пробуем зеркало: $m ($branch, новый формат)"
    write_alt_sources "$m"
    if alt_apt_update_ok; then
      if apt-cache show libmhash &>/dev/null || apt-cache show sudo &>/dev/null; then
        log "Репозиторий OK: $m"
        ok=1
        break
      fi
      log "update прошёл, но libmhash/sudo в кэше нет — следующее зеркало"
    fi
    log "Legacy layout для $m"
    write_alt_sources_legacy "$m"
    if alt_apt_update_ok; then
      if apt-cache show libmhash &>/dev/null || apt-cache show sudo &>/dev/null; then
        log "Репозиторий OK (legacy): $m"
        ok=1
        break
      fi
    fi
  done

  if [[ $ok -ne 1 ]]; then
    log "WARN: пакеты не подтверждены — пишем все зеркала в один list"
    {
      echo "# Auto by install_sn_lsp.sh — multi-mirror ($branch)"
      for m in "${mirrors[@]}"; do
        echo "rpm ${m} ${branch}/branch/x86_64 classic"
        echo "rpm ${m} ${branch}/branch/noarch classic"
      done
    } > /etc/apt/sources.list.d/sn-auto-alt.list
    alt_apt_update_ok || true
  fi

  log "Итоговый sn-auto-alt.list:"
  sed 's/^/  /' /etc/apt/sources.list.d/sn-auto-alt.list || true

  if apt-cache show libmhash &>/dev/null; then
    log "apt-cache видит libmhash — можно ставить зависимости"
  else
    log "WARN: apt-cache не видит libmhash (проверьте сеть до mirror.yandex.ru)"
  fi
}

# Зависимости SN до установки пакета (особенно ALT: libmhash, boost 1.76, sudo)
ensure_sn_dependencies() {
  log "Установка зависимостей Secret Net для ОС=$OS_ID"
  case "$OS_ID" in
    alt)
      ensure_repos_alt
      # Явный список из типичного Requires пакета 2509 c10f1 + то, что вернул rpm
      local deps=(
        sudo
        libmhash
        libboost_program_options1.76.0
        libboost_regex1.76.0
        libboost_log1.76.0
        libboost_filesystem1.76.0
        libboost_thread1.76.0
        libboost_system1.76.0
        libboost_chrono1.76.0
        libboost_atomic1.76.0
      )
      # Дополнить Requires из самого rpm (имена без (.so) и без rpmlib)
      local req
      while IFS= read -r req; do
        [[ -z "$req" ]] && continue
        [[ "$req" == rpmlib* ]] && continue
        [[ "$req" == *"("* ]] && continue
        [[ "$req" == /bin/* || "$req" == /usr/* ]] && continue
        # только простые имена пакетов
        if [[ "$req" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.+-]*$ ]]; then
          deps+=("$req")
        fi
      done < <(rpm -qpR "$SN_PKG" 2>/dev/null || true)

      local d branch="c10f1"
      [[ "${SN_PKG:-}" == *c10f2* ]] && branch="c10f2"
      [[ "${SN_PKG:-}" == *c10f1* ]] && branch="c10f1"

      for d in "${deps[@]}"; do
        if rpm -q "$d" &>/dev/null; then
          log "  уже есть: $d"
          continue
        fi
        log "  ставим зависимость: $d"
        apt-get install -y "$d" 2>&1 | tail -5 || log "  WARN: не удалось поставить $d"
      done

      # Контрольная проверка критичных
      local missing=()
      for d in sudo libmhash libboost_regex1.76.0 libboost_log1.76.0 libboost_program_options1.76.0; do
        rpm -q "$d" &>/dev/null || missing+=("$d")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        die "Не удалось установить зависимости ALT: ${missing[*]}
Проверьте сеть до mirror.yandex.ru / ftp.altlinux.org (ветка ${branch}).
Сейчас sn-auto-alt.list:
$(cat /etc/apt/sources.list.d/sn-auto-alt.list 2>/dev/null)
Вручную: apt-get update && apt-get install ${missing[*]}"
      fi
      log "Критичные зависимости ALT на месте"
      ;;
    astra)
      ensure_repos_astra
      # Типичные Depends secretnet 1.12-2509.astra2.12 (+ Pre-Depends)
      local deps=(
        apt-transport-https
        ca-certificates
        acl adduser binutils coreutils
        libpam-cracklib libcrack2
        libboost-filesystem1.62.0
        libboost-locale1.62.0
        libboost-program-options1.62.0
        libboost-regex1.62.0
        libboost-signals1.62.0
        libboost-iostreams1.62.0
        libboost-log1.62.0
        libcurl3 libmhash2 libmount1 libpci3
        libsasl2-modules passwd pcscd psmisc
        python3 python3-distutils sqlite3 sudo dbus procps
      )
      # Парсим Depends/Pre-Depends из deb
      local field req
      for field in Pre-Depends Depends; do
        while IFS= read -r req; do
          [[ -z "$req" ]] && continue
          # отрезать версии: pkg (>= 1.0) → pkg
          req="${req%%(*}"
          req="$(echo "$req" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -z "$req" || "$req" == *\|* ]] && continue
          if [[ "$req" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+_-]*$ ]]; then
            deps+=("$req")
          fi
        done < <(dpkg-deb -f "$SN_PKG" "$field" 2>/dev/null | tr ',' '\n')
      done

      local d
      for d in "${deps[@]}"; do
        if dpkg -s "$d" &>/dev/null; then
          log "  уже есть: $d"
          continue
        fi
        log "  ставим зависимость: $d"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$d" 2>&1 | tail -5 \
          || log "  WARN: не удалось поставить $d"
      done

      local missing=()
      for d in sudo libmhash2 libpam-cracklib; do
        dpkg -s "$d" &>/dev/null || missing+=("$d")
      done
      # boost из Depends пакета (1.62 на CE 2.12, на SE может отличаться)
      local boost_needed=() boost_missing=()
      for d in "${deps[@]}"; do
        [[ "$d" == libboost-* ]] || continue
        boost_needed+=("$d")
        dpkg -s "$d" &>/dev/null || boost_missing+=("$d")
      done
      if [[ ${#boost_needed[@]} -gt 0 && ${#boost_missing[@]} -eq ${#boost_needed[@]} ]]; then
        missing+=("${boost_missing[@]}")
      fi
      if [[ ${#missing[@]} -gt 0 ]]; then
        die "Не удалось установить зависимости Astra: ${missing[*]}
Проверьте сеть до dl.astralinux.ru / download.astralinux.ru.
sources:
$(cat /etc/apt/sources.list.d/sn-auto-astra.list 2>/dev/null || head -20 /etc/apt/sources.list 2>/dev/null)
Вручную: apt-get update && apt-get install ${missing[*]}"
      fi
      log "Критичные зависимости Astra на месте"
      ;;
    redos)
      dnf makecache -y 2>/dev/null || true
      ;;
  esac
}

ensure_repos() {
  case "$OS_ID" in
    redos) ensure_repos_redos ;;
    astra) ensure_repos_astra ;;
    alt)   ensure_repos_alt ;;
  esac
}

# Локальные rpm/deb ядра уже в --pkg-dir (офлайн комплект инженера)
find_local_kernel_pkg() {
  local kver="$1"
  local f
  # точное вхождение kver в имени файла
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    printf '%s\n' "$f"
    return 0
  done < <(find "$PKG_DIR" "$KERNEL_CACHE_DIR" /mnt/sn-auto-dvd /mnt/sn-auto-dvd/Packages \
            -maxdepth 3 -type f \( -name "*${kver}*.rpm" -o -name "*${kver}*.deb" \) 2>/dev/null | head -5)
  return 1
}

# Скачать rpm ядра с зеркал РЕД ОС по имени из матрицы SN
download_redos_kernel_rpm() {
  local kver="$1"
  local names mirrors paths name base url dest
  mkdir -p "$KERNEL_CACHE_DIR"
  dest="${KERNEL_CACHE_DIR}/kernel-lt-${kver}.rpm"
  [[ -f "$dest" && -s "$dest" ]] && { printf '%s\n' "$dest"; return 0; }

  names=(
    "kernel-lt-${kver}.rpm"
    "kernel-${kver}.rpm"
    "kernel-core-${kver}.rpm"
    "kernel-lt-core-${kver}.rpm"
  )
  # kver = 6.6.51-1.red80.x86_64 → иногда пакет без .x86_64 в mid
  local short="${kver%.x86_64}"
  names+=("kernel-lt-${short}.x86_64.rpm" "kernel-lt-${short}.rpm")

  mirrors=(
    "https://mirror.yandex.ru/redos/8.0/x86_64"
    "https://repo.red-soft.ru/redos/8.0/x86_64"
    "http://repo.red-soft.ru/redos/8.0/x86_64"
    "https://repo2.red-soft.ru/redos/8.0/x86_64"
  )
  paths=(
    "os/Packages"
    "os/Packages/k"
    "updates/Packages"
    "updates/Packages/k"
    "extras/Packages"
    "extras/Packages/k"
    "kernel"
    "kernel/Packages"
  )

  for name in "${names[@]}"; do
    for base in "${mirrors[@]}"; do
      for path in "${paths[@]}"; do
        url="${base}/${path}/${name}"
        if http_ok "$url"; then
          log "Скачивание ядра: $url"
          if [[ $DRY_RUN -eq 1 ]]; then
            printf '%s\n' "$url"
            return 0
          fi
          if http_get "$url" "$dest"; then
            printf '%s\n' "$dest"
            return 0
          fi
        fi
      done
    done
  done
  return 1
}

# РЕД ОС: найти пакет в dnf (включая --showduplicates)
redos_resolve_kernel_pkg() {
  local kver="$1"
  local cand line short
  short="${kver%.x86_64}"

  for cand in \
    "kernel-lt-${kver}" \
    "kernel-lt-${short}.x86_64" \
    "kernel-lt-${short}" \
    "kernel-${kver}" \
    "kernel-core-${kver}"
  do
    if rpm -q "$cand" &>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
    if dnf list --available "$cand" &>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done

  # repoquery по всем дубликатам
  line="$(dnf repoquery --available --showduplicates \
            --qf '%{name}-%{version}-%{release}.%{arch}' \
            'kernel-lt*' 'kernel' 'kernel-core*' 2>/dev/null \
          | grep -F "$short" | head -1 || true)"
  if [[ -n "$line" ]]; then
    printf '%s\n' "$line"
    return 0
  fi

  line="$(dnf list available 'kernel*' 2>/dev/null | awk -v v="$short" 'index($0,v){print $1; exit}' || true)"
  [[ -n "$line" ]] && { printf '%s\n' "$line"; return 0; }
  return 1
}

# Выбрать kver + способ установки: local rpm | dnf name | downloaded rpm
# Печатает:  KVER|METHOD|REF
# METHOD = boot|dnf|file
resolve_kernel_install() {
  local k already pkg localf dl
  already="$(boot_has_supported_kernel || true)"
  if [[ -n "$already" ]]; then
    printf '%s|boot|%s\n' "$already" "$already"
    return 0
  fi

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue

    localf="$(find_local_kernel_pkg "$k" || true)"
    if [[ -n "$localf" ]]; then
      log "Найден локальный пакет ядра для $k: $localf"
      printf '%s|file|%s\n' "$k" "$localf"
      return 0
    fi

    case "$OS_ID" in
      redos)
        if pkg="$(redos_resolve_kernel_pkg "$k")"; then
          printf '%s|dnf|%s\n' "$k" "$pkg"
          return 0
        fi
        ;;
      astra)
        if apt-cache show "linux-image-$k" &>/dev/null; then
          printf '%s|dnf|linux-image-%s\n' "$k" "$k"
          return 0
        fi
        ;;
      alt)
        pkg="$(apt-cache search --names-only kernel-image 2>/dev/null | grep -F "$k" | awk '{print $1}' | head -1 || true)"
        if [[ -n "$pkg" ]]; then
          printf '%s|dnf|%s\n' "$k" "$pkg"
          return 0
        fi
        ;;
    esac
  done <<< "$(printf '%s\n' "$PKG_KERNELS" | sort -V -r)"

  # Вторая волна: скачать с зеркал (РЕД ОС)
  if [[ "$OS_ID" == "redos" ]]; then
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      log "В репо нет $k — пробуем прямое скачивание с зеркал..."
      dl="$(download_redos_kernel_rpm "$k" || true)"
      if [[ -n "$dl" && -f "$dl" ]]; then
        printf '%s|file|%s\n' "$k" "$dl"
        return 0
      fi
    done <<< "$(printf '%s\n' "$PKG_KERNELS" | sort -V -r)"
  fi

  return 1
}

activate_kernel_redos() {
  local kver="$1" method="$2" ref="$3"
  local initrd
  log "РЕД ОС: ядро $kver способом $method ($ref)"
  [[ $DRY_RUN -eq 1 ]] && return 0

  case "$method" in
    dnf)
      dnf install -y "$ref" || dnf install -y --allowerasing "$ref"
      ;;
    file)
      dnf install -y "$ref" || rpm -Uvh --force "$ref"
      ;;
    boot) ;;
    *) die "Неизвестный method=$method" ;;
  esac

  [[ -e "/boot/vmlinuz-$kver" ]] || die "После установки нет /boot/vmlinuz-$kver (проверьте имя пакета)"

  initrd="/boot/initramfs-${kver}.img"
  if [[ ! -f "$initrd" ]]; then
    log "Сборка initramfs (dracut) для $kver"
    dracut -f --kver "$kver" "$initrd"
  fi
  grubby --update-kernel="/boot/vmlinuz-$kver" --initrd="$initrd"
  grubby --set-default "/boot/vmlinuz-$kver"
  log "Default kernel: $(grubby --default-kernel)"
}

activate_kernel_astra() {
  local kver="$1" method="$2" ref="$3"
  local boot_mnt boot_free free_m
  log "Astra: ядро $kver способом $method ($ref)"
  [[ $DRY_RUN -eq 1 ]] && return 0

  boot_mnt="/boot"
  boot_free="$(df -Pm "$boot_mnt" 2>/dev/null | awk 'NR==2 {print $4}')"
  free_m="${boot_free:-0}"
  if [[ "$free_m" =~ ^[0-9]+$ ]] && (( free_m < 100 )); then
    log "ERROR: мало места на /boot: ${free_m} МБ (нужно ≥100)"
    return 1
  fi
  log "Свободно на /boot: ${free_m} МБ"

  if [[ -f /etc/apt/sources.list.d/sn-auto-astra.list ]]; then
    awk '!seen[$0]++' /etc/apt/sources.list.d/sn-auto-astra.list > /tmp/sn-auto-astra.list.$$
    mv /tmp/sn-auto-astra.list.$$ /etc/apt/sources.list.d/sn-auto-astra.list
  fi

  apt-get update -y || true

  # Пакет могли уже поставить прошлым запуском — тогда только initrd+grub
  if [[ ! -e "/boot/vmlinuz-$kver" ]]; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
          -o Dpkg::Options::="--force-confdef" \
          -o Dpkg::Options::="--force-confold" \
          "$ref"; then
      log "apt install ядра вернул ошибку — dpkg --configure / apt -f / reinstall"
      DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
      DEBIAN_FRONTEND=noninteractive apt-get -f install -y || true
      DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$ref" || true
    fi
  else
    log "vmlinuz-$kver уже есть — не ставим пакет заново, чиним initrd и GRUB"
  fi

  if [[ ! -e "/boot/vmlinuz-$kver" ]]; then
    log "ERROR: после установки нет /boot/vmlinuz-$kver"
    return 1
  fi

  # Критично для Astra: модули PARSEC под ЭТО ядро до reboot
  astra_install_parsec_for_kernel "$kver" || return 1

  astra_rebuild_initrd "$kver" || return 1
  astra_set_grub_default "$kver" || true
  return 0
}

activate_kernel_alt() {
  local kver="$1" method="$2" ref="$3"
  log "ALT: ядро $kver способом $method ($ref)"
  [[ $DRY_RUN -eq 1 ]] && return 0
  apt-get update -y || true
  if [[ "$method" == "file" ]]; then
    apt-get install -y "$ref" || rpm -Uvh "$ref"
  else
    apt-get install -y "$ref"
  fi
  if command -v update-grub >/dev/null 2>&1; then
    update-grub || true
  elif command -v bootloader-reconfigure >/dev/null 2>&1; then
    bootloader-reconfigure || true
  fi
}

ensure_kernel() {
  load_kernels_from_sn_pkg
  mkdir -p "$KERNEL_CACHE_DIR"

  local cur target method ref resolved
  cur="$(uname -r)"
  log "Текущее ядро: $cur"

  if kernel_supported "$cur"; then
    log "OK: $cur есть в матрице пакета SN — менять ядро не нужно"
    return 0
  fi

  log "Ядро $cur НЕТ в матрице $(basename "$SN_PKG") — автоматическая смена"
  [[ $SKIP_KERNEL -eq 1 ]] && die "Несовместимое ядро $cur, а --skip-kernel задан."

  ensure_repos

  # уже в /boot
  target="$(boot_has_supported_kernel || true)"
  if [[ -n "$target" && "$target" != "$cur" ]]; then
    log "Переключаем загрузчик на уже установленное $target"
    [[ $DRY_RUN -eq 1 ]] && return 0
    case "$OS_ID" in
      redos)
        local initrd="/boot/initramfs-${target}.img"
        [[ -f "$initrd" ]] || dracut -f --kver "$target" "$initrd"
        grubby --update-kernel="/boot/vmlinuz-$target" --initrd="$initrd"
        grubby --set-default "/boot/vmlinuz-$target"
        ;;
      astra|alt)
        if [[ "$OS_ID" == "astra" ]]; then
          astra_install_parsec_for_kernel "$target" || die "Нет PARSEC для уже установленного $target — поставьте parsec-linux-modules-$target"
          astra_rebuild_initrd "$target" || die "Не удалось починить initrd для уже установленного $target"
          astra_set_grub_default "$target"
        else
          update-grub 2>/dev/null || bootloader-reconfigure 2>/dev/null || true
          command -v grubby >/dev/null 2>&1 && [[ -e "/boot/vmlinuz-$target" ]] && \
            grubby --set-default "/boot/vmlinuz-$target" 2>/dev/null || true
        fi
        ;;
    esac
    do_reboot 1
  fi

  # Уже выбранное /boot выше обработали. Ставим ядро из матрицы (с запасными вариантами).
  local tried=()
  while true; do
    resolved="$(resolve_kernel_install || true)"
    [[ -n "$resolved" ]] || break
    target="${resolved%%|*}"
    method="$(printf '%s' "$resolved" | cut -d'|' -f2)"
    ref="$(printf '%s' "$resolved" | cut -d'|' -f3-)"
    # не зацикливаться на том же ядре
    local skip=0 t
    for t in "${tried[@]+"${tried[@]}"}"; do
      [[ "$t" == "$target" ]] && skip=1 && break
    done
    if [[ $skip -eq 1 ]]; then
      # убрать из видимости: пометить через переменную PKG_KERNELS без этого k — сложно;
      # для astra просто break после повтора
      break
    fi
    tried+=("$target")
    log "Целевое ядро: $target | способ: $method | источник: $ref"
    set +e
    case "$OS_ID" in
      astra) activate_kernel_astra "$target" "$method" "$ref"; rc=$? ;;
      redos) activate_kernel_redos "$target" "$method" "$ref"; rc=$? ;;
      alt)   activate_kernel_alt "$target" "$method" "$ref"; rc=$? ;;
      *) rc=1 ;;
    esac
    set -e
    if [[ ${rc:-1} -eq 0 ]]; then
      do_reboot 1
    fi
    log "WARN: ядро $target не встало (rc=${rc:-?}) — пробуем следующее из матрицы"
    # временно исключить target из списка, чтобы resolve взял другой
    PKG_KERNELS="$(printf '%s\n' "$PKG_KERNELS" | grep -vxF "$target" || true)"
    [[ -n "$PKG_KERNELS" ]] || break
  done

  die "Не удалось автоматически достать ни одно ядро из матрицы SN (пробовали: ${tried[*]:-ничего}).

Исходная матрица пакета — см. лог выше / содержимое deb.
Частые причины на Astra: мало места на /boot, сломанный initramfs.
Проверьте: df -h /boot ; dpkg --configure -a ; apt-get -f install -y

Положите в --pkg-dir готовый linux-image-*.deb из матрицы и перезапустите."
}

#------------------------------------------------------------------------------
install_sn_package() {
  local cur; cur="$(uname -r)"
  load_kernels_from_sn_pkg
  kernel_supported "$cur" || die "Отказ ставить SN: ядро $cur отсутствует в матрице пакета.
Поддерживаемые:
$PKG_KERNELS"
  log "Установка SN на ядро $cur (подтверждено пакетом)"
  [[ $DRY_RUN -eq 1 ]] && { log "[dry-run] install $SN_PKG"; return 0; }

  # Репозитории + зависимости ДО пакета SN (иначе ALT падает на libmhash/boost)
  ensure_repos
  ensure_sn_dependencies

  local sn_abs
  sn_abs="$(readlink -f "$SN_PKG" 2>/dev/null || realpath "$SN_PKG" 2>/dev/null || echo "$SN_PKG")"

  case "$OS_ID" in
    astra)
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$sn_abs"; then
        log "apt-get install deb не удался — apt-get -f и повтор"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -f || true
        ensure_sn_dependencies
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$sn_abs" \
          || DEBIAN_FRONTEND=noninteractive dpkg -i "$sn_abs" \
          || die "Не удалось установить SN deb. Смотрите: dpkg-deb -f $sn_abs Depends"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -f || true
      fi
      dpkg -l secretnet 2>/dev/null | grep -qE '^ii' || die "Пакет secretnet не установился"
      log "secretnet установлен: $(dpkg-query -W -f='${Package} ${Version}\n' secretnet 2>/dev/null)"
      ;;
    redos)
      dnf install -y "$sn_abs"
      ;;
    alt)
      # Важно: полный путь; apt подтянет оставшиеся deps из уже настроенных репо
      if ! apt-get install -y "$sn_abs"; then
        log "apt-get install локального rpm не удался — доустанавливаем -f и повторяем"
        apt-get install -y -f || true
        # Ещё раз явные deps на случай частичного успеха
        ensure_sn_dependencies
        if ! apt-get install -y "$sn_abs"; then
          log "Пробуем rpm -Uvh после deps..."
          rpm -Uvh "$sn_abs" || die "Не удалось установить SN. Смотрите зависимости: rpm -qpR $sn_abs"
        fi
      fi
      rpm -q secretnet || die "Пакет secretnet не установился"
      log "secretnet установлен: $(rpm -q secretnet)"
      ;;
  esac
  do_reboot 3
}

install_firewall_and_license() {
  export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:${PATH}"

  if [[ $SKIP_FIREWALL -eq 0 && -n "$FW_PKG" ]]; then
    log "Установка ПМЭ (firewall)"
    if [[ $DRY_RUN -eq 0 ]]; then
      case "$OS_ID" in
        astra)
          ensure_repos_astra
          local fw_abs
          fw_abs="$(readlink -f "$FW_PKG" 2>/dev/null || realpath "$FW_PKG" 2>/dev/null || echo "$FW_PKG")"
          DEBIAN_FRONTEND=noninteractive apt-get install -y "$fw_abs" \
            || { DEBIAN_FRONTEND=noninteractive dpkg -i "$fw_abs"; DEBIAN_FRONTEND=noninteractive apt-get install -y -f; }
          ;;
        redos)
          dnf install -y "$FW_PKG"
          ;;
        alt)
          ensure_repos_alt
          local fw_abs
          fw_abs="$(readlink -f "$FW_PKG" 2>/dev/null || realpath "$FW_PKG" 2>/dev/null || echo "$FW_PKG")"
          apt-get install -y "$fw_abs" || rpm -Uvh "$fw_abs"
          ;;
      esac
    fi
  fi

  if [[ -n "$LICENSE_FILE" ]]; then
    log "Установка лицензии: $LICENSE_FILE"
    if [[ $DRY_RUN -eq 0 ]]; then
      # станция могла быть LOCKED
      if command -v snunblock >/dev/null 2>&1; then
        snunblock 2>/dev/null || true
      fi
      snlicensectl -c "$LICENSE_FILE" || log "WARN: snlicensectl -c вернул ошибку"
      snlicensectl -s || true
    fi
  else
    log "Лицензия не указана (--license) — пропуск snlicensectl"
  fi

  # модули
  log "Модули sn*:"
  lsmod | grep -E '^sn' || log "WARN: модули sn* не загружены (проверьте snkernel / reboot)"
  log "Политики snpolctl скрипт НЕ настраивает — делайте вручную под заказчика."
}

print_summary() {
  export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:${PATH}"
  log "========== ИТОГ =========="
  log "ОС: $OS_ID | ядро: $(uname -r)"
  case "$OS_ID" in
    astra) dpkg -l 2>/dev/null | grep -iE 'secretnet|snlsp' || true ;;
    *)     rpm -qa 2>/dev/null | grep -iE 'secretnet|snlsp' || true ;;
  esac
  systemctl is-active sn.service snkernel.service snstart.service 2>/dev/null || true
  lsmod | grep -E '^sn' || true
  command -v snlicensectl >/dev/null && snlicensectl -s 2>/dev/null || true
  deploy_helper_scripts
  log "Лог: $LOG_FILE"
  log "Готово."
  rm -f "$MARKER_NEED_REBOOT"
  save_state 5
}

# configure / backup рядом с установщиком → /opt/sn-lsp-auto/
deploy_helper_scripts() {
  local here dest="/opt/sn-lsp-auto" s src
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$dest"
  for s in configure_sn_lsp.sh backup_sn_policies.sh install_sn_lsp.sh; do
    src=""
    if [[ -f "$here/$s" ]]; then
      src="$here/$s"
    elif [[ -n "${PKG_DIR:-}" && -f "$PKG_DIR/../$s" ]]; then
      src="$PKG_DIR/../$s"
    elif [[ -f "/opt/sn-lsp-auto/$s" ]]; then
      src="/opt/sn-lsp-auto/$s"
    fi
    if [[ -n "$src" ]]; then
      install -m 0755 "$src" "$dest/$s"
      log "Скрипт: $dest/$s"
    fi
  done
  if [[ -x "$dest/configure_sn_lsp.sh" ]]; then
    log "Политики (меню): sudo bash $dest/configure_sn_lsp.sh"
  else
    log "WARN: configure_sn_lsp.sh не найден — скопируйте вручную в $dest/"
  fi
}

#------------------------------------------------------------------------------
# PHASE:
#  0 — старт / detect / packages / kernel check+fix → reboot→1
#  1 — после reboot ядра: снова kernel check, install SN → reboot→3
#  3 — после reboot SN: firewall + license → 5
#  5 — done
#------------------------------------------------------------------------------
main() {
  parse_args "$@"
  need_root
  ensure_state_dir

  local phase=0
  if [[ -n "$FORCE_PHASE" ]]; then
    phase="$FORCE_PHASE"
  elif load_state; then
    phase="${PHASE:-0}"
    # восстановить пути из state, если CLI не переопределил лицензию пустотой намеренно
    [[ -n "${SN_PKG:-}" ]] || true
    log "Продолжение с этапа PHASE=$phase (state: $STATE_FILE)"
  fi

  detect_os
  find_packages
  load_kernels_from_sn_pkg

  # если пакеты переопределили через CLI — обновить state-поля
  save_state "$phase"

  case "$phase" in
    0)
      log "=== Этап 0: проверка/настройка ядра ==="
      ensure_kernel
      save_state 1
      # если reboot не понадобился — сразу ставим SN
      log "=== Этап 1: установка SN ==="
      install_sn_package
      ;;
    1)
      log "=== Этап 1: проверка ядра после reboot + установка SN ==="
      ensure_kernel
      # уже стоит?
      if rpm -q secretnet &>/dev/null || dpkg -l secretnet 2>/dev/null | grep -q '^ii'; then
        log "SN уже установлен — переход к ПМЭ/лицензии"
        save_state 3
        install_firewall_and_license
        print_summary
      else
        install_sn_package
      fi
      ;;
    3)
      log "=== Этап 3: ПМЭ + лицензия ==="
      install_firewall_and_license
      print_summary
      ;;
    5)
      log "Установка уже завершена (PHASE=5). Для повтора: rm -rf $STATE_DIR && ..."
      print_summary
      ;;
    *)
      die "Неизвестный PHASE=$phase"
      ;;
  esac
}

main "$@"
