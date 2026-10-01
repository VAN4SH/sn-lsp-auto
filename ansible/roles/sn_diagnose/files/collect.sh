#!/bin/bash
# Сбор фактов для диагностики SN LSP. Вывод — одна JSON-строка в stdout.
set -euo pipefail

json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")' 2>/dev/null \
    || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')"
}

one_line() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

hostname_s="$(hostname -s 2>/dev/null || hostname)"
fqdn="$(hostname -f 2>/dev/null || echo "$hostname_s")"
kernel="$(uname -r)"
arch="$(uname -m)"
uptime_s="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
virt="$(systemd-detect-virt 2>/dev/null || echo none)"
python3_bin="$(command -v python3 2>/dev/null || true)"

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
pkg_family=""
install_supported="no"
case "$os_id_raw" in
  astra) sn_os="astra"; pkg_family="deb"; install_supported="yes" ;;
  redos|red-os) sn_os="redos"; pkg_family="rpm"; install_supported="yes" ;;
  altlinux|altlinuxsp|alt) sn_os="alt"; pkg_family="rpm"; install_supported="yes" ;;
  debian|ubuntu|linuxmint) sn_os="debian"; pkg_family="deb" ;;
  centos|rhel|rocky|almalinux|ol|fedora) sn_os="centos"; pkg_family="rpm" ;;
esac
id_like="${ID_LIKE:-}"
if [[ -z "$sn_os" ]]; then
  blob_id="$(printf '%s' "$os_pretty $os_name $os_id_raw $id_like")"
  if echo "$blob_id" | grep -qi astra; then sn_os="astra"; pkg_family="deb"; install_supported="yes"
  elif echo "$blob_id" | grep -qiE 'ред.?ос|red.?os'; then sn_os="redos"; pkg_family="rpm"; install_supported="yes"
  elif echo "$blob_id" | grep -qiE 'alt'; then sn_os="alt"; pkg_family="rpm"; install_supported="yes"
  elif echo "$blob_id" | grep -qiE 'debian|ubuntu'; then sn_os="debian"; pkg_family="deb"
  elif echo "$blob_id" | grep -qiE 'centos|rhel|rocky|alma'; then sn_os="centos"; pkg_family="rpm"
  fi
fi
[[ -n "$sn_os" ]] || sn_os="unknown"
if [[ -z "$pkg_family" ]]; then
  if [[ -d /etc/apt && ! -d /etc/yum.repos.d ]]; then pkg_family="deb"
  elif [[ -d /etc/yum.repos.d || -d /etc/dnf ]]; then pkg_family="rpm"
  fi
fi

lsb_description=""
if command -v lsb_release >/dev/null 2>&1; then
  lsb_description="$(lsb_release -d 2>/dev/null | sed 's/^Description:[[:space:]]*//' || true)"
fi

# Короткая метка редакции/версии — для любой ОС, не только Astra
os_flavor="${os_version:-}"
astra_edition=""
if [[ "$sn_os" == "astra" ]]; then
  blob="$(printf '%s\n' "$os_version" "$os_pretty" "$lsb_description" \
    "$(cat /etc/astra_version 2>/dev/null || true)")"
  if echo "$blob" | grep -qiE '(^|[^0-9])1\.8([^0-9]|$)'; then
    astra_edition="se18"
  elif echo "$blob" | grep -qiE '(^|[^0-9])1\.7([^0-9]|$)'; then
    astra_edition="se17"
  elif echo "$blob" | grep -qiE '(^|[^0-9])2\.12([^0-9]|$)|orel'; then
    astra_edition="ce212"
  elif echo "$blob" | grep -qiE '(^|[^0-9])1\.6([^0-9]|$)'; then
    astra_edition="se16"
  else
    case "$kernel" in
      6.*) astra_edition="se18" ;;
      4.15.*) astra_edition="se17" ;;
      *) astra_edition="unknown" ;;
    esac
  fi
  os_flavor="$astra_edition"
elif [[ "$sn_os" == "alt" && -r /etc/altlinux-release ]]; then
  os_flavor="$(head -n1 /etc/altlinux-release 2>/dev/null || echo "$os_version")"
elif [[ "$sn_os" == "redos" && -r /etc/redos-release ]]; then
  os_flavor="$(head -n1 /etc/redos-release 2>/dev/null || echo "$os_version")"
fi
[[ -n "$os_flavor" ]] || os_flavor="${os_pretty:-unknown}"

mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"

disk_root_free_gb="0"
disk_boot_free_gb=""
boot_separate="no"
if command -v df >/dev/null 2>&1; then
  disk_root_free_gb="$(df -BP / 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
  if findmnt -n /boot >/dev/null 2>&1; then
    boot_separate="yes"
  fi
  if [[ -d /boot ]]; then
    disk_boot_free_gb="$(df -BP /boot 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024}')"
  fi
fi

kernels_boot=""
if [[ -d /boot ]]; then
  kernels_boot="$(
    find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null \
      | sed 's/^vmlinuz-//' | sort -u | awk 'NF{printf "%s%s", (n++?",":""), $0}' || true
  )"
fi

parsec="na"
if [[ "$sn_os" == "astra" ]]; then
  parsec="missing"
  cfg="/boot/config-${kernel}"
  mb="/lib/modules/${kernel}/modules.builtin"
  if [[ -f "$cfg" ]] && grep -qE '^CONFIG_SECURITY_PARSEC=y|^CONFIG_DEFAULT_SECURITY_PARSEC=y|^CONFIG_PARSEC=y' "$cfg" 2>/dev/null; then
    parsec="builtin"
  elif [[ -f "$mb" ]] && grep -q 'parsec_kernel\.ko' "$mb" 2>/dev/null; then
    parsec="builtin"
  fi
  if find "/lib/modules/${kernel}" \( -name 'parsec.ko' -o -name 'parsec.ko.xz' -o -name 'parsec.ko.gz' -o -name 'parsec.ko.zst' \) 2>/dev/null | grep -q .; then
    parsec="module"
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
repos_sample=""
# Репозитории по типу пакетного менеджера, без привязки к одной ОС
if [[ -d /etc/apt ]]; then
  repos_sample="$(
    grep -RshE '^[[:space:]]*(deb|rpm)[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
      | grep -vE '^\s*#' | grep -vE 'cdrom:' | head -n 8 || true
  )"
fi
if [[ -z "$repos_sample" && -d /etc/yum.repos.d ]]; then
  repos_sample="$(
    awk -F= '
      /^\[/ {sec=$0}
      $1=="baseurl" || $1=="metalink" || $1=="mirrorlist" {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        if ($2 != "" && $2 !~ /^file:/) print sec " " $2
      }
    ' /etc/yum.repos.d/*.repo 2>/dev/null | head -n 8 || true
  )"
fi
if [[ -n "$repos_sample" ]]; then
  repos_ok="yes"
elif [[ -d /etc/apt || -d /etc/yum.repos.d ]]; then
  repos_ok="no"
fi
repos_sample="$(one_line "$repos_sample")"
repos_sample="${repos_sample:0:500}"

sn_installed="no"
snpolctl_path=""
if command -v snpolctl >/dev/null 2>&1; then
  sn_installed="yes"
  snpolctl_path="$(command -v snpolctl)"
elif [[ -x /opt/secretnet/bin/snpolctl || -x /opt/secretnet/sbin/snpolctl ]]; then
  sn_installed="yes"
  snpolctl_path="/opt/secretnet"
fi

sn_packages=""
if command -v rpm >/dev/null 2>&1; then
  sn_packages="$(rpm -qa 2>/dev/null | grep -iE 'secretnet|snlsp|sn-lsp' | sort | awk 'NF{printf "%s%s", (n++?",":""), $0}' || true)"
fi
if [[ -z "$sn_packages" ]] && command -v dpkg-query >/dev/null 2>&1; then
  sn_packages="$(
    dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null \
      | grep -iE 'secretnet|snlsp|sn-lsp' | awk 'NF{printf "%s%s", (n++?",":""), $0}' || true
  )"
fi
[[ -n "$sn_packages" ]] && sn_installed="yes"

sn_pkg_hint="${sn_packages%%,*}"

sn_modules=""
sn_modules="$(lsmod 2>/dev/null | awk 'NR>1 && $1 ~ /^sn/ {printf "%s%s", (n++?",":""), $1}' || true)"

sn_services=""
svc_parts=()
for s in sn.service snkernel.service snstart.service; do
  if systemctl list-unit-files "$s" >/dev/null 2>&1; then
    st="$(systemctl is-active "$s" 2>/dev/null || true)"
    [[ -n "$st" ]] || st="unknown"
    svc_parts+=("${s}=${st}")
  fi
done
sn_services="$(IFS=,; echo "${svc_parts[*]:-}")"

license_summary=""
if [[ -x /opt/secretnet/sbin/snlicensectl || -x /opt/secretnet/bin/snlicensectl ]]; then
  export PATH="/opt/secretnet/sbin:/opt/secretnet/bin:${PATH}"
fi
if command -v snlicensectl >/dev/null 2>&1; then
  license_summary="$(snlicensectl -s 2>&1 | head -n 40 || true)"
  license_summary="$(one_line "$license_summary")"
  license_summary="${license_summary:0:700}"
fi

phase=""
state_file="/var/lib/sn-lsp-autoinstall/state"
if [[ -r "$state_file" ]]; then
  phase="$(grep -E '^PHASE=' "$state_file" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
fi

ips="$(hostname -I 2>/dev/null | xargs || true)"

printf '{'
printf '"hostname":%s,' "$(json_escape "$hostname_s")"
printf '"fqdn":%s,' "$(json_escape "$fqdn")"
printf '"ips":%s,' "$(json_escape "$ips")"
printf '"kernel":%s,' "$(json_escape "$kernel")"
printf '"kernels_boot":%s,' "$(json_escape "$kernels_boot")"
printf '"arch":%s,' "$(json_escape "$arch")"
printf '"virt":%s,' "$(json_escape "$virt")"
printf '"uptime_sec":%s,' "$uptime_s"
printf '"os_id_raw":%s,' "$(json_escape "$os_id_raw")"
printf '"os_name":%s,' "$(json_escape "$os_name")"
printf '"os_pretty":%s,' "$(json_escape "$os_pretty")"
printf '"os_version":%s,' "$(json_escape "$os_version")"
printf '"lsb_description":%s,' "$(json_escape "$lsb_description")"
printf '"sn_os":%s,' "$(json_escape "$sn_os")"
printf '"os_flavor":%s,' "$(json_escape "$os_flavor")"
printf '"pkg_family":%s,' "$(json_escape "$pkg_family")"
printf '"install_supported":%s,' "$(json_escape "$install_supported")"
printf '"astra_edition":%s,' "$(json_escape "$astra_edition")"
printf '"mem_mb":%s,' "$mem_mb"
printf '"disk_root_free_gb":%s,' "$(json_escape "$disk_root_free_gb")"
printf '"disk_boot_free_gb":%s,' "$(json_escape "${disk_boot_free_gb}")"
printf '"boot_separate":%s,' "$(json_escape "$boot_separate")"
printf '"selinux":%s,' "$(json_escape "$selinux")"
printf '"apparmor":%s,' "$(json_escape "$apparmor")"
printf '"parsec":%s,' "$(json_escape "$parsec")"
printf '"repos_ok":%s,' "$(json_escape "$repos_ok")"
printf '"repos_sample":%s,' "$(json_escape "$repos_sample")"
printf '"sn_installed":%s,' "$(json_escape "$sn_installed")"
printf '"snpolctl":%s,' "$(json_escape "$snpolctl_path")"
printf '"sn_pkg":%s,' "$(json_escape "$sn_pkg_hint")"
printf '"sn_packages":%s,' "$(json_escape "$sn_packages")"
printf '"sn_modules":%s,' "$(json_escape "$sn_modules")"
printf '"sn_services":%s,' "$(json_escape "$sn_services")"
printf '"license_summary":%s,' "$(json_escape "$license_summary")"
printf '"python3":%s,' "$(json_escape "$python3_bin")"
printf '"phase":%s' "$(json_escape "$phase")"
printf '}\n'
