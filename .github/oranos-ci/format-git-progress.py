#!/usr/bin/env python3
"""Convert Git's carriage-return progress into bounded GitHub Actions log lines.

Git writes progress to stderr using '\r'. A pipe is not a TTY, so --progress
must be passed to Git explicitly. This formatter emits each new 5% bucket and
at least one update every 15s, preserving non-progress output and errors.
"""
import re
import sys
import time

PERCENT = re.compile(r"(?<!\d)(\d{1,3})%")
last_progress = {}


def emit(line: str) -> None:
    line = line.strip()
    if not line:
        return
    match = PERCENT.search(line)
    if match is None:
        print(line, flush=True)
        return
    percentage = int(match.group(1))
    if percentage > 100:
        print(line, flush=True)
        return
    phase = line.split(":", 2)[:2]
    key = ":".join(phase) if line.startswith("remote:") else phase[0]
    now = time.monotonic()
    previous = last_progress.get(key)
    if previous is not None:
        prev_pct, prev_ts = previous
        if percentage == prev_pct and now - prev_ts < 15:
            return
        if percentage < 100 and percentage // 5 == prev_pct // 5 and now - prev_ts < 15:
            return
    last_progress[key] = (percentage, now)
    print(line, flush=True)


def main() -> None:
    pending = ""
    while True:
        chunk = sys.stdin.buffer.read1(8192)
        if not chunk:
            break
        pending += chunk.decode("utf-8", "replace")
        parts = re.split(r"[\r\n]", pending)
        pending = parts.pop()
        for part in parts:
            emit(part)
    emit(pending)


if __name__ == "__main__":
    main()
