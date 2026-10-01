#!/usr/bin/env python3
"""Собрать отчёты диагностики из hostvars, переданных через stdin как JSON-массив."""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: write_report.py REPORT_DIR < hosts.json_array", file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    rows = json.load(sys.stdin)
    if not isinstance(rows, list):
        print("expected JSON array", file=sys.stderr)
        return 2

    (out / "hosts.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    fields = [
        "host",
        "groups",
        "sn_os",
        "os_flavor",
        "pkg_family",
        "install_supported",
        "os_pretty",
        "kernel",
        "kernel_in_matrix",
        "kernels_boot",
        "disk_root_free_gb",
        "disk_boot_free_gb",
        "mem_mb",
        "repos_ok",
        "parsec",
        "sn_installed",
        "sn_packages",
        "sn_services",
        "phase",
        "ready",
        "notes",
    ]
    detail_fields = [
        ("Хост", "host"),
        ("Группы", "groups"),
        ("ОС", "sn_os"),
        ("Редакция/версия", "os_flavor"),
        ("Семейство пакетов", "pkg_family"),
        ("Установщик SN", "install_supported"),
        ("Описание", "os_pretty"),
        ("lsb", "lsb_description"),
        ("Ядро", "kernel"),
        ("Ядро в матрице SN", "kernel_in_matrix"),
        ("Ядра в /boot", "kernels_boot"),
        ("Свободно / ГБ", "disk_root_free_gb"),
        ("Свободно /boot ГБ", "disk_boot_free_gb"),
        ("RAM МБ", "mem_mb"),
        ("Вирт.", "virt"),
        ("IP", "ips"),
        ("Репозитории", "repos_ok"),
        ("Строки репозиториев", "repos_sample"),
        ("PARSEC", "parsec"),
        ("SELinux", "selinux"),
        ("SN установлен", "sn_installed"),
        ("Пакеты SN", "sn_packages"),
        ("Модули sn*", "sn_modules"),
        ("Службы", "sn_services"),
        ("Лицензия", "license_summary"),
        ("PHASE", "phase"),
        ("Готов к установке", "ready"),
        ("Заметки", "notes"),
    ]
    ready: list[str] = []
    blocked: list[str] = []

    with (out / "summary.csv").open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in sorted(rows, key=lambda x: x.get("host", "")):
            row = {k: r.get(k, "") for k in fields}
            w.writerow(row)
            name = r.get("host", "")
            if str(r.get("ready", "")).lower() in ("yes", "true", "1"):
                ready.append(name)
            else:
                blocked.append(name)

    (out / "ready.txt").write_text("\n".join(ready) + ("\n" if ready else ""), encoding="utf-8")
    (out / "blocked.txt").write_text(
        "\n".join(blocked) + ("\n" if blocked else ""), encoding="utf-8"
    )

    blocks: list[str] = []
    for r in sorted(rows, key=lambda x: x.get("host", "")):
        lines = [f"== {r.get('host', '?')} =="]
        for title, key in detail_fields:
            val = r.get(key, "")
            if val in (None, ""):
                continue
            lines.append(f"{title}: {val}")
        blocks.append("\n".join(lines))
    (out / "detail.txt").write_text("\n\n".join(blocks) + ("\n" if blocks else ""), encoding="utf-8")

    print(str(out))
    print(f"ready={len(ready)} blocked={len(blocked)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
