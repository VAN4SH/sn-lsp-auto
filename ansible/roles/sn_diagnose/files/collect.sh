#!/bin/bash
# Сбор фактов для диагностики SN LSP. Вывод — одна JSON-строка в stdout.
set -euo pipefail

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")' 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')"
}

hostname_s="$(hostname -s 2>/dev/null || hostname)"
fqdn="$(hostname -f 2>/dev/null || echo "$hostname_s")"
kernel="$(uname -r)"
arch="$(uname -m)"
uptime_s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"

os_id_raw=""
os_name=""
os_pretty=""
os_version=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id_raw="${ID:-}"
  os_name="${NAME:-}"
  os_pretty="${PRETTY_NAME:-}"
  os_version="${VERSION_ID:-}"
fi

sn_os=""
case "$os_id_raw" in
  astra) sn_os="astra" ;;
  redos|red-os) sn_os="redos" ;;
  altlinux|altlinuxsp|alt) sn_os="alt" ;;
esac
if [[ -z "$sn_os" ]]; then
  echo "$os_pretty $os_name $os_id_raw" | grep -qi astra && sn_os="astra" || true
  echo "$os_pretty $os_name $os_id_raw" | grep -qiE 'ред.?ос|red.?os' && sn_os="redos" || true
  echo "$os_pretty $os_name $os_id_raw" | grep -qiE 'alt' && sn_os="alt" || true
fi
[[ -n "$sn_os" ]] || sn_os="unknown"

mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"

disk_root_free_gb="0"
disk_boot_free_gb=""
if command -v df >/dev/null 2>&1; then
  disk_root_free_gb="$(df -BP / 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
  if mountpoint -q /boot 2>/dev/null || [[ -d /boot ]]; then
    disk_boot_free_gb="$(df -BP /boot 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
  fi
fi

selinux="none"
if command -v getenforce >/dev/null 2>&1; then
  selinux="$(getenforce 2>/dev/null || echo unknown)"
fi
apparmor="none"
if command -v aa-status >/dev/null 2>&1; then
  apparmor="present"
elif [[ -d /sys/kernel/security/apparmor ]]; then
  apparmor="present"
fi

repos_ok="unknown"
case "$sn_os" in
  astra|alt)
    if [[ -d /etc/apt ]]; then
      if grep -RshE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
          | grep -vE '^\s*#' | grep -vE 'cdrom:' | grep -q .; then
        repos_ok="yes"
      else
        repos_ok="no"
      fi
    fi
    ;;
  redos)
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      if ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
        repos_ok="yes"
      else
        repos_ok="no"
      fi
    fi
    ;;
esac

sn_installed="no"
snpolctl_path=""
if command -v snpolctl >/dev/null 2>&1; then
  sn_installed="yes"
  snpolctl_path="$(command -v snpolctl)"
elif [[ -x /opt/secretnet/bin/snpolctl ]]; then
  sn_installed="yes"
  snpolctl_path="/opt/secretnet/bin/snpolctl"
fi

sn_pkg_hint=""
if command -v dpkg-query >/dev/null 2>&1; then
  sn_pkg_hint="$(dpkg-query -W -f='${Package} ${Version}\n' 'sn-lsp*' 2>/dev/null | head -n 1 || true)"
elif command -v rpm >/dev/null 2>&1; then
  sn_pkg_hint="$(rpm -qa 'sn-lsp*' 2>/dev/null | head -n 1 || true)"
fi

phase=""
state_file="/var/lib/sn-lsp-autoinstall/state"
if [[ -f "$state_file" ]]; then
  phase="$(grep -E '^PHASE=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
fi

ips="$(hostname -I 2>/dev/null | xargs || true)"

printf '{'
printf '"hostname":%s,' "$(json_escape "$hostname_s")"
printf '"fqdn":%s,' "$(json_escape "$fqdn")"
printf '"ips":%s,' "$(json_escape "$ips")"
printf '"kernel":%s,' "$(json_escape "$kernel")"
printf '"arch":%s,' "$(json_escape "$arch")"
printf '"uptime_sec":%s,' "$uptime_s"
printf '"os_id_raw":%s,' "$(json_escape "$os_id_raw")"
printf '"os_name":%s,' "$(json_escape "$os_name")"
printf '"os_pretty":%s,' "$(json_escape "$os_pretty")"
printf '"os_version":%s,' "$(json_escape "$os_version")"
printf '"sn_os":%s,' "$(json_escape "$sn_os")"
printf '"mem_mb":%s,' "$mem_mb"
printf '"disk_root_free_gb":%s,' "$(json_escape "$disk_root_free_gb")"
printf '"disk_boot_free_gb":%s,' "$(json_escape "${disk_boot_free_gb}")"
printf '"selinux":%s,' "$(json_escape "$selinux")"
printf '"apparmor":%s,' "$(json_escape "$apparmor")"
printf '"repos_ok":%s,' "$(json_escape "$repos_ok")"
printf '"sn_installed":%s,' "$(json_escape "$sn_installed")"
printf '"snpolctl":%s,' "$(json_escape "$snpolctl_path")"
printf '"sn_pkg":%s,' "$(json_escape "$sn_pkg_hint")"
printf '"phase":%s' "$(json_escape "$phase")"
printf '}\n'
