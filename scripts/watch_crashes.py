#!/usr/bin/env python3
"""Watch / pull WebAutoParking crash reports via pymobiledevice3 (USB).

LAN app logs die with the process. Device .ips crash reports do not.

Usage:
  py -3.9 scripts/watch_crashes.py              # live watch (Ctrl+C to stop)
  py -3.9 scripts/watch_crashes.py --pull       # pull + summarize existing
  py -3.9 scripts/watch_crashes.py --pull --watch
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

BUNDLE_HINT = "WebAutoParking"
OUT_DIR = Path(__file__).resolve().parents[1] / "crashlogs"
PY = [sys.executable, "-m", "pymobiledevice3"]


def run(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(PY + args, check=check)


def summarize_ips(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    if not lines:
        return f"{path.name}: empty"
    try:
        meta = json.loads(lines[0])
        body = json.loads("\n".join(lines[1:])) if len(lines) > 1 else {}
    except json.JSONDecodeError as exc:
        return f"{path.name}: parse error ({exc})"

    exc = body.get("exception") or {}
    term = body.get("termination") or {}
    bt = body.get("lastExceptionBacktrace") or []
    tops = [frame.get("symbol", "?") for frame in bt[:5]]
    ts = meta.get("timestamp") or body.get("captureTime") or "?"
    sig = f"{exc.get('type', '?')} {exc.get('signal', '')}".strip()
    why = term.get("indicator") or (body.get("asi") and str(body["asi"])) or ""
    stack = " <- ".join(tops) if tops else "(no ObjC exception backtrace)"
    return f"{path.name}\n  time: {ts}\n  {sig} | {why}\n  {stack}"


def pull_matching() -> list[Path]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    run(["crash", "flush"], check=False)
    run(["crash", "pull", str(OUT_DIR), "--match", BUNDLE_HINT])
    return sorted(OUT_DIR.glob(f"{BUNDLE_HINT}*.ips"), key=lambda p: p.stat().st_mtime, reverse=True)


def watch_live() -> None:
    print(f"Watching for new {BUNDLE_HINT} crash reports (USB). Ctrl+C to stop.")
    print("Reproduce the crash on the phone; a report will print here.\n")
    # Name filter is applied by pymobiledevice3 when the report filename matches.
    run(["crash", "watch", "--name", BUNDLE_HINT])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pull", action="store_true", help="Pull and summarize existing crashes")
    parser.add_argument("--watch", action="store_true", help="Live-watch for new crash reports")
    args = parser.parse_args()

    if not args.pull and not args.watch:
        args.watch = True

    if args.pull:
        files = pull_matching()
        if not files:
            print(f"No {BUNDLE_HINT}*.ips found under {OUT_DIR}")
        else:
            print(f"Pulled {len(files)} report(s) -> {OUT_DIR}\n")
            for path in files[:12]:
                print(summarize_ips(path))
                print()

    if args.watch:
        watch_live()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
