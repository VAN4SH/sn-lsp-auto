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
        "os_pretty",
        "kernel",
        "kernel_in_matrix",
        "disk_root_free_gb",
        "mem_mb",
        "repos_ok",
        "sn_installed",
        "phase",
        "ready",
        "notes",
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
    print(str(out))
    print(f"ready={len(ready)} blocked={len(blocked)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
