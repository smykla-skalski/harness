#!/usr/bin/env bash
set -euo pipefail

window="${1:-15m}"

log_predicate='eventMessage CONTAINS[c] "__previews_injection_perform_first_jit_link" OR eventMessage CONTAINS[c] "__previews_injection_register_swift_extension_entry_section" OR eventMessage CONTAINS[c] "__previews_injection_run_user_entrypoint"'

log_dump="$(mktemp /tmp/harness-monitor-preview-log.XXXXXX)"
trap 'rm -f "$log_dump"' EXIT

/usr/bin/log show --last "$window" --style compact --predicate "$log_predicate" >"$log_dump"

python3 - "$log_dump" <<'PY'
from __future__ import annotations

import re
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime

line_re = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+\S+\s+(?P<process>.+?)\[(?P<pid>\d+):[^\]]+\].*(?P<phase>__previews_injection_[^ ]+)"
)


@dataclass
class Session:
    process: str
    pid: int
    first_jit: datetime | None = None
    register: datetime | None = None
    entrypoint: datetime | None = None


sessions: dict[tuple[str, int], Session] = {}
completed: list[Session] = []

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
    for raw_line in handle:
        match = line_re.search(raw_line)
        if not match:
            continue

        timestamp = datetime.strptime(match.group("timestamp"), "%Y-%m-%d %H:%M:%S.%f")
        process = match.group("process").strip()
        pid = int(match.group("pid"))
        phase = match.group("phase")
        key = (process, pid)
        session = sessions.setdefault(key, Session(process=process, pid=pid))

        if phase == "__previews_injection_perform_first_jit_link":
            session.first_jit = timestamp
            session.register = None
            session.entrypoint = None
        elif phase == "__previews_injection_register_swift_extension_entry_section":
            session.register = timestamp
        elif phase == "__previews_injection_run_user_entrypoint":
            session.entrypoint = timestamp
            if session.first_jit is not None:
                completed.append(session)
                sessions[key] = Session(process=process, pid=pid)

if not completed:
    print("No completed preview JIT sessions found in the requested window.", file=sys.stderr)
    sys.exit(1)

durations = [
    (session.entrypoint - session.first_jit).total_seconds()
    for session in completed
    if session.first_jit is not None and session.entrypoint is not None
]

latest = completed[-1]
latest_total = (latest.entrypoint - latest.first_jit).total_seconds()
latest_register = None
if latest.register is not None:
    latest_register = (latest.register - latest.first_jit).total_seconds()

print(f"Preview JIT sessions: {len(durations)}")
print(f"Latest host: {latest.process} (pid {latest.pid})")
print(f"Latest total: {latest_total:.3f}s")
if latest_register is not None:
    print(f"Latest first-link to register: {latest_register:.3f}s")
print(f"Average total: {statistics.mean(durations):.3f}s")
print(f"Median total: {statistics.median(durations):.3f}s")
print(f"Best total: {min(durations):.3f}s")
print(f"Worst total: {max(durations):.3f}s")
PY
