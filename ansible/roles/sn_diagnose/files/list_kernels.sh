#!/bin/bash
# Список ядер из пакета SN на jump. Аргументы: пути к .deb/.rpm.
set -euo pipefail

extract_paths() {
  local pkg="$1"
  case "$pkg" in
    *.deb)
      dpkg-deb -c "$pkg" 2>/dev/null | awk '{print $NF}'
      ;;
    *.rpm)
      if command -v rpm >/dev/null 2>&1 && rpm -qlp "$pkg" >/dev/null 2>&1; then
        rpm -qlp "$pkg" 2>/dev/null
      elif command -v rpm2cpio >/dev/null 2>&1; then
        rpm2cpio "$pkg" 2>/dev/null | cpio -t 2>/dev/null
      fi
      ;;
  esac
}

for pkg in "$@"; do
  [[ -f "$pkg" ]] || continue
  extract_paths "$pkg" | sed -n 's|.*/lib/modules/\([^/]*\)/.*|\1|p'
done | sort -u
