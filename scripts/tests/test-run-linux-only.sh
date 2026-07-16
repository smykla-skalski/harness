#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/run-linux-only-test.XXXXXX")"

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() {
  printf 'test-run-linux-only: %s\n' "$*" >&2
  exit 1
}

write_uname() {
  local directory="$1"
  local host_os="$2"
  mkdir -p "$directory"
  printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' '\''%s'\''\n' "$host_os" >"$directory/uname"
  chmod +x "$directory/uname"
}

runner="$SANDBOX/runner"
cat >"$runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker="$1"
shift
printf '%s\n' "$@" >"$marker"
exit "${RUN_LINUX_ONLY_TEST_STATUS:-0}"
EOF
chmod +x "$runner"

darwin_bin="$SANDBOX/darwin-bin"
write_uname "$darwin_bin" Darwin
darwin_marker="$SANDBOX/darwin-ran"
darwin_output="$(
  PATH="$darwin_bin:$PATH" \
    "$ROOT/scripts/run-linux-only.sh" "$runner" "$darwin_marker" alpha
)"
[[ ! -e "$darwin_marker" ]] || fail "Darwin path executed the wrapped command"
[[ "$darwin_output" == "skipping Linux-only command on macOS" ]] \
  || fail "Darwin path did not report the skip"

linux_bin="$SANDBOX/linux-bin"
write_uname "$linux_bin" Linux
linux_marker="$SANDBOX/linux-ran"
set +e
PATH="$linux_bin:$PATH" RUN_LINUX_ONLY_TEST_STATUS=37 \
  "$ROOT/scripts/run-linux-only.sh" \
  "$runner" "$linux_marker" alpha "two words"
linux_status=$?
set -e
[[ "$linux_status" -eq 37 ]] || fail "Linux path did not preserve exit status 37"
linux_arguments="$(cat "$linux_marker")"
[[ "$linux_arguments" == $'alpha\ntwo words' ]] \
  || fail "Linux path did not preserve command arguments"

unknown_bin="$SANDBOX/unknown-bin"
write_uname "$unknown_bin" FreeBSD
unknown_marker="$SANDBOX/unknown-ran"
set +e
PATH="$unknown_bin:$PATH" \
  "$ROOT/scripts/run-linux-only.sh" "$runner" "$unknown_marker" \
  >"$SANDBOX/unknown-output" 2>&1
unknown_status=$?
set -e
[[ "$unknown_status" -eq 1 ]] || fail "unknown host OS should return status 1"
[[ ! -e "$unknown_marker" ]] || fail "unknown host OS executed the wrapped command"

set +e
"$ROOT/scripts/run-linux-only.sh" >"$SANDBOX/usage-output" 2>&1
usage_status=$?
set -e
[[ "$usage_status" -eq 2 ]] || fail "missing command should return usage status 2"

python3 - "$ROOT/.mise.toml" "$ROOT/.github/workflows/harness-monitor.yml" <<'PY'
import pathlib
import re
import shlex
import sys

mise_path = pathlib.Path(sys.argv[1])
workflow_path = pathlib.Path(sys.argv[2])
expected_tasks = {
    "test:unit",
    "test:integration",
    "test:workers",
    "test:slow",
    "remote-daemon:systemd-e2e",
    "systemd:check",
    "harness:check:feature-isolation",
    "harness:check:rust",
}
wrapper = "./scripts/run-linux-only.sh"
cargo = "./scripts/cargo-local.sh"
covered_tasks = set()
task_name = None

for line in mise_path.read_text().splitlines():
    task_header = re.fullmatch(r'\[tasks\."([^"]+)"\]', line)
    if task_header:
        task_name = task_header.group(1)
        continue
    if "-p harness-systemd" not in line:
        continue
    command = line.strip().rstrip(",")
    if command.startswith('"') and command.endswith('"'):
        command = command[1:-1]
    arguments = shlex.split(command)
    selects_systemd = any(
        arguments[index:index + 2] == ["-p", "harness-systemd"]
        for index in range(len(arguments) - 1)
    )
    if not selects_systemd:
        continue
    if task_name is None:
        raise SystemExit(f"harness-systemd selection has no task: {line}")
    covered_tasks.add(task_name)
    if arguments[:2] != [wrapper, cargo]:
        raise SystemExit(
            f"{task_name} selects harness-systemd without the Linux-only wrapper: {command}"
        )

if covered_tasks != expected_tasks:
    missing = sorted(expected_tasks - covered_tasks)
    unexpected = sorted(covered_tasks - expected_tasks)
    raise SystemExit(
        f"unexpected harness-systemd gate coverage; missing={missing}, unexpected={unexpected}"
    )

workflow = workflow_path.read_text()
if "harness-systemd" in workflow:
    raise SystemExit("macOS Harness Monitor workflow selects harness-systemd")
PY
