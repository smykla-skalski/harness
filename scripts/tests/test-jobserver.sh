#!/usr/bin/env bash
set -uo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
JOBSERVER="$ROOT/scripts/harness-jobserver.py"

# The granted width reaches the command as an environment variable, so the probe
# has to expand it in the child. Keeping that in a script rather than an inline
# `sh -c` keeps the intent readable and out of shellcheck's single-quote rule.
PROBE_DIR="$(mktemp -d)"
PROBE_SCRIPT="$PROBE_DIR/probe"
PROBE_HOLDER="$PROBE_DIR/holder"
cat >"$PROBE_SCRIPT" <<'PROBE'
#!/usr/bin/env bash
printf %s "$PROBE"
PROBE
cat >"$PROBE_HOLDER" <<'PROBE'
#!/usr/bin/env bash
printf %s "$PROBE" > "$1"
sleep 3
PROBE
chmod +x "$PROBE_SCRIPT" "$PROBE_HOLDER"

passed=0
failed=0
started_pools=()

pass() {
  printf 'PASS: %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  failed=$((failed + 1))
}

# Each scenario gets its own synthetic repo root, and the pool path is a hash of
# that root, so scenarios never share a supervisor.
fake_root() {
  printf '/synthetic/%s/%s' "$$" "$1"
}

pool_dir_for() {
  python3 - "$JOBSERVER" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.pool_dir(sys.argv[2]))
PY
}

track_pool() {
  started_pools+=("$(pool_dir_for "$1")")
}

# The lock file outlives the process that wrote it, and a dead supervisor's pid
# gets recycled - on a box also running other agents' builds, signalling it
# blind can kill something that has nothing to do with this suite.
is_supervisor_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *harness-jobserver.py*supervise*) return 0 ;;
  esac
  return 1
}

kill_supervisor() {
  if is_supervisor_pid "$1"; then
    kill "$1" 2>/dev/null || true
  fi
  return 0
}

stop_pool_at_dir() {
  kill_supervisor "$(head -1 "$1/lock" 2>/dev/null || true)"
}

cleanup() {
  local dir pid
  for dir in "${started_pools[@]:-}"; do
    [[ -n "$dir" ]] || continue
    pid="$(head -1 "$dir/lock" 2>/dev/null || true)"
    kill_supervisor "$pid"
    rm -rf "$dir" 2>/dev/null || true
  done
  rm -rf "$PROBE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

tokens_in_fifo() {
  python3 - "$1" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NONBLOCK)
total = 0
while True:
    try:
        chunk = os.read(fd, 4096)
    except BlockingIOError:
        break
    if not chunk:
        break
    total += len(chunk)
if total:
    os.write(fd, b"+" * total)   # put them back
print(total)
PY
}

scenario_ensure_starts_pool_and_prints_makeflags() {
  local name="ensure starts a pool and prints usable MAKEFLAGS"
  local root; root="$(fake_root ensure)"
  track_pool "$root"

  local out
  out="$(python3 "$JOBSERVER" ensure --repo-root "$root" --budget 6 2>&1)"
  if [[ ! "$out" =~ ^MAKEFLAGS=-j6\ --jobserver-auth=fifo:/ ]]; then
    fail "$name (got: $out)"
    return
  fi
  local fifo="${out#*fifo:}"
  if [[ ! -p "$fifo" ]]; then
    fail "$name (not a FIFO: $fifo)"
    return
  fi
  if [[ "$(tokens_in_fifo "$fifo")" != "6" ]]; then
    fail "$name (FIFO not filled to budget)"
    return
  fi
  pass "$name"
}

scenario_ensure_is_idempotent() {
  local name="a second ensure reuses the running supervisor"
  local root; root="$(fake_root idem)"
  track_pool "$root"
  local dir; dir="$(pool_dir_for "$root")"

  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1
  local first; first="$(head -1 "$dir/lock" 2>/dev/null)"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1
  local second; second="$(head -1 "$dir/lock" 2>/dev/null)"

  if [[ -z "$first" ]] || [[ "$first" != "$second" ]]; then
    fail "$name (supervisor pid changed: '$first' -> '$second')"
    return
  fi
  pass "$name"
}

scenario_run_exports_granted_width() {
  local name="run exports the granted width and returns tokens after"
  local root; root="$(fake_root width)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 5 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"

  local seen
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 3 --env PROBE -- \
    "$PROBE_SCRIPT")"
  # 3 tokens granted plus the implicit slot every process already owns.
  if [[ "$seen" != "4" ]]; then
    fail "$name (expected width 4, got '$seen')"
    return
  fi
  sleep 0.3
  if [[ "$(tokens_in_fifo "$dir/fifo")" != "5" ]]; then
    fail "$name (tokens not returned after the command exited)"
    return
  fi
  pass "$name"
}

scenario_grant_is_capped_by_budget() {
  local name="a grant never exceeds the pool budget"
  local root; root="$(fake_root cap)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1

  local seen
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 99 --env PROBE -- \
    "$PROBE_SCRIPT")"
  if [[ "$seen" != "4" ]]; then
    fail "$name (expected 3 tokens + implicit slot = 4, got '$seen')"
    return
  fi
  pass "$name"
}

scenario_second_client_gets_the_remainder() {
  local name="a concurrent client gets only what is left"
  local root; root="$(fake_root share)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1

  local holder_out; holder_out="$(mktemp)"
  python3 "$JOBSERVER" run --repo-root "$root" --max 3 --env PROBE -- \
    "$PROBE_HOLDER" "$holder_out" &
  local holder=$!
  sleep 1

  local seen
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 4 --env PROBE -- \
    "$PROBE_SCRIPT")"
  wait "$holder" 2>/dev/null
  # First client took 3 of 4; only 1 remains, so the second sees 1 + implicit.
  if [[ "$seen" != "2" ]]; then
    fail "$name (expected width 2 for the second client, got '$seen')"
    rm -f "$holder_out"
    return
  fi
  rm -f "$holder_out"
  pass "$name"
}

scenario_sigkilled_client_returns_its_tokens() {
  local name="a SIGKILLed client's tokens are reclaimed"
  local root; root="$(fake_root reclaim)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"

  python3 "$JOBSERVER" run --repo-root "$root" --max 4 --env PROBE -- sleep 60 &
  local victim=$!
  sleep 1
  if [[ "$(tokens_in_fifo "$dir/fifo")" != "0" ]]; then
    fail "$name (pool was not drained by the holder)"
    kill -9 "$victim" 2>/dev/null
    return
  fi

  # SIGKILL leaves the client no chance to release anything itself.
  pkill -9 -P "$victim" 2>/dev/null
  kill -9 "$victim" 2>/dev/null
  wait "$victim" 2>/dev/null
  sleep 1

  if [[ "$(tokens_in_fifo "$dir/fifo")" != "4" ]]; then
    fail "$name (tokens leaked after SIGKILL)"
    return
  fi
  pass "$name"
}

scenario_foreign_owned_pool_dir_is_refused() {
  local name="a symlinked pool directory is refused"
  local root; root="$(fake_root unsafe)"
  local dir; dir="$(pool_dir_for "$root")"
  local decoy; decoy="$(mktemp -d)"

  mkdir -p "$(dirname "$dir")"
  rm -rf "$dir"
  ln -s "$decoy" "$dir"

  local status=0
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1 || status=$?
  rm -f "$dir"
  rm -rf "$decoy"

  if (( status == 0 )); then
    fail "$name (symlinked pool directory was accepted)"
    return
  fi
  pass "$name"
}

scenario_missing_pool_still_runs_the_command() {
  local name="run still executes when no pool is reachable"
  local root; root="$(fake_root nopool)"

  local seen
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 4 --env PROBE --floor 2 -- \
    "$PROBE_SCRIPT")"
  # No supervisor, so the floor applies and the command must still run.
  if [[ "$seen" != "2" ]]; then
    fail "$name (expected floor width 2, got '$seen')"
    return
  fi
  pass "$name"
}

scenario_run_preserves_argument_separators() {
  local name="run preserves a separator inside the command"
  local root; root="$(fake_root separator)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 2 >/dev/null 2>&1

  # Only the separator argparse needs may be stripped. Test runners forward
  # their own arguments after a second one, and eating it silently rewrites
  # the command so those flags land on the runner instead of the test binary.
  local seen
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 1 --env PROBE -- \
    printf '%s|' a -- b)"
  if [[ "$seen" != "a|--|b|" ]]; then
    fail "$name (expected 'a|--|b|', got '$seen')"
    return
  fi
  pass "$name"
}

scenario_lock_file_holds_only_the_current_pid() {
  local name="the lock file is truncated to the current pid"
  local root; root="$(fake_root lockfile)"
  track_pool "$root"
  local dir; dir="$(pool_dir_for "$root")"

  mkdir -p "$dir"
  # A longer stale pid from an earlier supervisor must not survive underneath.
  printf '99999999\n' > "$dir/lock"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 2 >/dev/null 2>&1

  local lines; lines="$(wc -l < "$dir/lock" | tr -d ' ')"
  if [[ "$lines" != "1" ]]; then
    fail "$name (lock file has $lines lines: $(tr '\n' ' ' < "$dir/lock"))"
    return
  fi
  pass "$name"
}

scenario_ensure_reports_the_running_budget() {
  local name="ensure reports the running pool's width, not the one asked for"
  local root; root="$(fake_root budget)"
  track_pool "$root"

  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1
  # A second caller cannot resize a live pool, so echoing its own number back
  # would advertise a width the FIFO was never filled to.
  local out; out="$(python3 "$JOBSERVER" ensure --repo-root "$root" --budget 9 2>/dev/null)"

  if [[ "$out" != *"-j3 "* ]]; then
    fail "$name (expected -j3 from the running pool, got: $out)"
    return
  fi
  pass "$name"
}

scenario_pool_location_ignores_the_user_variable() {
  local name="the pool location is the same whatever USER says"
  local root; root="$(fake_root userenv)"
  local named unnamed absent
  named="$(USER=alpha pool_dir_for "$root")"
  unnamed="$(USER=beta pool_dir_for "$root")"
  # A daemon-spawned build inherits no USER at all, and a second pool for the
  # same uid would hand out the whole budget twice.
  absent="$(unset USER; pool_dir_for "$root")"

  if [[ "$named" != "$unnamed" ]]; then
    fail "$name (USER=alpha gave $named, USER=beta gave $unnamed)"
    return
  fi
  if [[ "$named" != "$absent" ]]; then
    fail "$name (USER set gave $named, USER unset gave $absent)"
    return
  fi
  if [[ "$named" != *"/harness-jobserver-$(id -u)/"* ]]; then
    fail "$name (expected the uid in the path, got $named)"
    return
  fi
  pass "$name"
}

scenario_a_non_fifo_at_the_pool_path_is_replaced() {
  local name="a stale non-FIFO at the pool path is replaced, not opened"
  local out
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import importlib.util, os, stat, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

results = []
with tempfile.TemporaryDirectory() as directory:
    # A leftover regular file opens cleanly and then reports an empty pool.
    fifo = os.path.join(directory, "fifo")
    with open(fifo, "wb") as handle:
        handle.write(b"junk")
    pool = mod.Pool(directory, 3)
    results.append("file->%s/%d" % (stat.S_ISFIFO(os.lstat(fifo).st_mode), pool._drain()))

with tempfile.TemporaryDirectory() as directory:
    # A directory takes the other route: unlink refuses it, so the supervisor
    # died on every spawn and each ensure paid the startup timeout forever.
    fifo = os.path.join(directory, "fifo")
    os.mkdir(fifo)
    with open(os.path.join(fifo, "junk"), "wb") as handle:
        handle.write(b"junk")
    pool = mod.Pool(directory, 3)
    results.append("dir->%s/%d" % (stat.S_ISFIFO(os.lstat(fifo).st_mode), pool._drain()))

with tempfile.TemporaryDirectory() as directory:
    # A symlink is the dangerous one: the refill writes tokens into the target.
    victim = os.path.join(directory, "victim")
    with open(victim, "wb") as handle:
        handle.write(b"precious")
    fifo = os.path.join(directory, "fifo")
    os.symlink(victim, fifo)
    pool = mod.Pool(directory, 3)
    with open(victim, "rb") as handle:
        intact = handle.read() == b"precious"
    results.append("link->%s/%d/%s" % (stat.S_ISFIFO(os.lstat(fifo).st_mode), pool._drain(), intact))

print(" ".join(results))
PY
)"
  if [[ "$out" != "file->True/3 dir->True/3 link->True/3/True" ]]; then
    fail "$name (expected a real FIFO with 3 tokens and an untouched target, got: $out)"
    return
  fi
  pass "$name"
}

scenario_acquire_surfaces_a_real_read_error() {
  local name="acquire raises a real read error instead of reporting an empty pool"
  local out
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import errno, importlib.util, os, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory() as directory:
    pool = mod.Pool(directory, 4)
    real_read = os.read

    # Scoped to the pool fd so the rest of the interpreter keeps working.
    def broken_read(fd, size):
        if fd == pool.fifo_fd:
            raise OSError(errno.EIO, "simulated device failure")
        return real_read(fd, size)

    os.read = broken_read
    try:
        got = pool.acquire(2)
    except OSError as exc:
        print("RAISED", exc.errno)
    else:
        print("SWALLOWED", got)
    finally:
        os.read = real_read
PY
)"
  if [[ "$out" != "RAISED $(python3 -c 'import errno; print(errno.EIO)')" ]]; then
    fail "$name (expected the EIO to propagate, got: $out)"
    return
  fi
  pass "$name"
}

scenario_idle_exit_leaves_no_tokens_behind() {
  local name="an idle supervisor leaves no tokens in the FIFO for its successor"
  local out
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import importlib.util, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory() as directory:
    pool = mod.Pool(directory, 3)
    # The supervisor answers a True by exiting, so whatever is still in the pipe
    # afterwards is what a build could take out from under the next supervisor.
    print("EXITS", pool.idle_and_whole(), "LEFTOVER", pool._drain())
PY
)"
  if [[ "$out" != "EXITS True LEFTOVER 0" ]]; then
    fail "$name (expected a whole idle pool to exit empty, got: $out)"
    return
  fi
  pass "$name"
}

scenario_partial_pool_keeps_its_tokens() {
  local name="a partly held pool keeps serving the tokens it still has"
  local out
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import importlib.util, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory() as directory:
    pool = mod.Pool(directory, 3)
    # Stand in for a build holding one token through the FIFO: the supervisor
    # must not exit, and must not eat the two tokens that are still free.
    pool._read_tokens(1)
    print("EXITS", pool.idle_and_whole(), "LEFTOVER", pool._drain())
PY
)"
  if [[ "$out" != "EXITS False LEFTOVER 2" ]]; then
    fail "$name (expected the pool to stay up with 2 tokens, got: $out)"
    return
  fi
  pass "$name"
}

scenario_signal_death_reports_a_shell_signal_status() {
  local name="a signal-killed child reports the shell's signal status"
  local root; root="$(fake_root signal)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 2 >/dev/null 2>&1

  # subprocess reports -9; passing that straight out of a shell wrapper wraps to
  # 247 and decodes as a signal that does not exist.
  local status=0
  python3 "$JOBSERVER" run --repo-root "$root" --max 1 --env PROBE -- \
    sh -c 'kill -9 $$' || status=$?
  if (( status != 137 )); then
    fail "$name (expected 137 for SIGKILL, got $status)"
    return
  fi
  status=0
  python3 "$JOBSERVER" run --repo-root "$root" --max 1 --env PROBE -- \
    sh -c 'kill -TERM $$' || status=$?
  if (( status != 143 )); then
    fail "$name (expected 143 for SIGTERM, got $status)"
    return
  fi
  pass "$name"
}

scenario_split_request_is_still_granted() {
  local name="a request split across packets is still granted"
  local root; root="$(fake_root split)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"

  # A stream socket keeps no message boundaries, so send the line in pieces.
  local granted
  granted="$(python3 - "$dir/sock" <<'PY'
import socket, sys, time
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.connect(sys.argv[1])
for piece in (b"ACQ", b"UIRE ", b"3", b"\n"):
    c.sendall(piece)
    time.sleep(0.05)
buf = b""
while b"\n" not in buf:
    chunk = c.recv(64)
    if not chunk:
        break
    buf += chunk
print(buf.partition(b"\n")[0].decode().strip())
PY
)"
  if [[ "$granted" != "GRANTED 3" ]]; then
    fail "$name (expected 'GRANTED 3', got '$granted')"
    return
  fi
  pass "$name"
}

scenario_junk_at_either_runtime_path_is_cleared() {
  local name="a directory at the fifo or the socket path does not wedge startup"
  local entry status dir
  # Both paths reach the same trap: unlink refuses a directory, the supervisor
  # dies before serving, and every ensure then pays the startup timeout.
  for entry in fifo sock; do
    local root; root="$(fake_root "junk-$entry")"
    track_pool "$root"
    dir="$(pool_dir_for "$root")"
    mkdir -p "$dir/$entry"
    : >"$dir/$entry/leftover"

    status=0
    python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1 || status=$?
    if (( status != 0 )); then
      fail "$name (a directory at '$entry' left the pool unreachable, status=$status)"
      return
    fi
    if [[ ! -p "$dir/fifo" || ! -S "$dir/sock" ]]; then
      fail "$name (after clearing '$entry' the pool is not usable)"
      return
    fi
    stop_pool_at_dir "$dir"
  done
  pass "$name"
}

scenario_restart_does_not_mint_a_second_budget() {
  local name="a restart adopts the pipe instead of refilling it"
  local out
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import importlib.util, os, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

results = []

with tempfile.TemporaryDirectory() as directory:
    results.append("fresh=%d" % mod.Pool(directory, 3)._drain())

with tempfile.TemporaryDirectory() as directory:
    # What a killed supervisor leaves behind: one token in the pipe and two
    # still out with a build that is running. Refilling to a full budget here
    # is what put five tokens on a three-token machine.
    fifo = os.path.join(directory, "fifo")
    os.mkfifo(fifo, 0o600)
    fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    os.write(fd, mod.TOKEN)
    results.append("killed=%d" % mod.Pool(directory, 3)._drain())
    os.close(fd)

with tempfile.TemporaryDirectory() as directory:
    # A supervisor that left through the idle path drained the pipe only after
    # verifying nothing was outstanding, so its successor may fill again.
    fifo = os.path.join(directory, "fifo")
    os.mkfifo(fifo, 0o600)
    with open(os.path.join(directory, mod.CLEAN_MARKER), "w", encoding="utf-8") as handle:
        handle.write("\n")
    results.append("clean=%d" % mod.Pool(directory, 3)._drain())

print(" ".join(results))
PY
)"
  if [[ "$out" != "fresh=3 killed=1 clean=3" ]]; then
    fail "$name (expected 'fresh=3 killed=1 clean=3', got: $out)"
    return
  fi
  pass "$name"
}

scenario_oversized_request_cannot_kill_the_pool() {
  local name="an out-of-range request cannot take the pool down"
  local root; root="$(fake_root oversized)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"
  local pid; pid="$(head -1 "$dir/lock" 2>/dev/null)"

  # os.read raises OverflowError past a C ssize_t, and that is neither OSError
  # nor RuntimeError, so it escaped every handler and killed the supervisor.
  python3 - "$dir/sock" <<'PY' >/dev/null 2>&1 || true
import socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(5.0)
c.connect(sys.argv[1])
c.sendall(b"ACQUIRE 100000000000000000000000000000\n")
try:
    c.recv(64)
except OSError:
    pass
PY

  if ! kill -0 "$pid" 2>/dev/null; then
    fail "$name (the supervisor died at pid $pid)"
    return
  fi
  local granted
  granted="$(python3 "$JOBSERVER" run --repo-root "$root" --max 2 --env PROBE -- "$PROBE_SCRIPT")"
  if [[ "$granted" != "3" ]]; then
    fail "$name (pool unusable after the oversized request, granted width '$granted')"
    return
  fi
  pass "$name"
}

scenario_a_wiped_pool_does_not_wedge_its_successor() {
  local name="a supervisor whose directory was wiped leaves its successor alone"
  local root; root="$(fake_root wiped)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"
  local first; first="$(head -1 "$dir/lock" 2>/dev/null)"

  # Exactly what this suite's own cleanup does: drop the directory while the
  # supervisor is still running. The successor then binds a fresh socket at the
  # same path, well inside the 5s the first one takes to notice.
  rm -rf "$dir"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1
  local second; second="$(head -1 "$dir/lock" 2>/dev/null)"

  if [[ -z "$second" || "$first" == "$second" ]]; then
    fail "$name (no successor took over: first='$first' second='$second')"
    return
  fi

  # Wait out the first supervisor's teardown, which is where it used to remove
  # a socket that was no longer its own.
  local waited=0
  while (( waited < 30 )) && kill -0 "$first" 2>/dev/null; do
    sleep 0.5
    waited=$((waited + 1))
  done
  if kill -0 "$first" 2>/dev/null; then
    fail "$name (the wiped supervisor never exited, still holding the lock)"
    return
  fi
  if [[ ! -S "$dir/sock" ]]; then
    fail "$name (the successor's socket was removed)"
    return
  fi

  local status=0
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 3 >/dev/null 2>&1 || status=$?
  if (( status != 0 )); then
    fail "$name (pool unreachable after the wipe, status=$status)"
    return
  fi
  pass "$name"
}

scenario_nonsense_widths_are_refused() {
  local name="a width below one is refused instead of building a dead pool"
  local root; root="$(fake_root nonsense)"
  local dir; dir="$(pool_dir_for "$root")"
  local status=0 spec

  # Each of these used to be accepted and then fail silently: a pool nothing
  # can draw from looks exactly like a healthy one from outside.
  for spec in "ensure --budget 0" "ensure --budget -1" "supervise --budget 0"; do
    status=0
    # shellcheck disable=SC2086
    python3 "$JOBSERVER" $spec --repo-root "$root" >/dev/null 2>&1 || status=$?
    if (( status == 0 )); then
      fail "$name ('$spec' was accepted)"
      return
    fi
  done

  status=0
  python3 "$JOBSERVER" run --repo-root "$root" --max 0 -- true >/dev/null 2>&1 || status=$?
  if (( status == 0 )); then
    fail "$name ('run --max 0' was accepted)"
    return
  fi
  if [[ -e "$dir/fifo" ]]; then
    fail "$name (a pool was created anyway at $dir)"
    return
  fi
  pass "$name"
}

scenario_cleanup_only_signals_a_supervisor() {
  local name="cleanup tells a live supervisor apart from any other pid"
  local root; root="$(fake_root killguard)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 2 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"
  local pid; pid="$(head -1 "$dir/lock" 2>/dev/null || true)"

  if ! is_supervisor_pid "$pid"; then
    fail "$name (did not recognise the running supervisor at pid '$pid')"
    return
  fi
  # The lock file outlives its writer, so a recycled pid is any live process
  # that is not ours - this shell stands in for one.
  if is_supervisor_pid "$$"; then
    fail "$name (would have signalled this test shell at pid $$)"
    return
  fi
  pass "$name"
}

scenario_a_client_that_never_reads_cannot_wedge_the_pool() {
  local name="a client that stops reading does not stall the other clients"
  local root; root="$(fake_root deafclient)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 4 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"

  local answer
  answer="$(python3 - "$dir/sock" <<'PY'
import socket, sys

path = sys.argv[1]
# Ask for zero so the flood cannot exhaust the pool; the point is the replies
# piling up in the server's send buffer, not the tokens.
deaf = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
# Bounded: a wedged server stops reading too, and an unbounded send here would
# hang this test instead of failing it.
deaf.settimeout(10.0)
deaf.connect(path)
try:
    deaf.sendall(b"ACQUIRE 0\n" * 4000)
except OSError:
    pass

other = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
other.settimeout(20.0)
try:
    other.connect(path)
    other.sendall(b"ACQUIRE 2\n")
    buf = b""
    while b"\n" not in buf:
        chunk = other.recv(64)
        if not chunk:
            break
        buf += chunk
    print(buf.partition(b"\n")[0].decode().strip() or "EMPTY")
except OSError as exc:
    print(f"BLOCKED {exc.__class__.__name__}")
PY
)"
  if [[ "$answer" != "GRANTED 2" ]]; then
    fail "$name (second client got '$answer')"
    return
  fi
  pass "$name"
}

scenario_pipelined_requests_are_all_answered() {
  local name="every request in one packet is answered, not just the first"
  local root; root="$(fake_root pipelined)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 6 >/dev/null 2>&1
  local dir; dir="$(pool_dir_for "$root")"

  # Handling one line per readable event left the rest sitting in the server's
  # buffer, which both stalled them and let the buffer grow without a bound.
  local replies
  replies="$(python3 - "$dir/sock" <<'PY'
import socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(5.0)
c.connect(sys.argv[1])
c.sendall(b"ACQUIRE 1\n" * 3)
buf = b""
try:
    while buf.count(b"\n") < 3:
        chunk = c.recv(64)
        if not chunk:
            break
        buf += chunk
except OSError:
    pass
print(buf.count(b"GRANTED"))
PY
)"
  if [[ "$replies" != "3" ]]; then
    fail "$name (expected 3 grants, got $replies)"
    return
  fi
  pass "$name"
}

scenario_symlinked_pool_parent_is_refused() {
  local name="a symlinked pool parent is refused"
  local out
  # Checked against a private path, never the real pool root. Moving that root
  # aside made every other build on the host fail to reach its own pool, and a
  # concurrent ensure recreating it turned the restore into a nested directory.
  out="$(python3 - "$JOBSERVER" 2>&1 <<'PY'
import importlib.util, os, sys, tempfile

spec = importlib.util.spec_from_file_location("js", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

with tempfile.TemporaryDirectory() as base:
    decoy = os.path.join(base, "decoy")
    os.mkdir(decoy)
    # Validating only the leaf let a pre-planted parent stand, and
    # os.path.isdir follows symlinks, so the whole pool landed inside it.
    parent = os.path.join(base, "parent")
    os.symlink(decoy, parent)
    try:
        mod.prepare_pool_dir(os.path.join(parent, "pool"))
    except RuntimeError:
        print("REFUSED")
    else:
        print("ACCEPTED")
    print("decoy entries:", len(os.listdir(decoy)))
PY
)"
  if [[ "$out" != "REFUSED"*"decoy entries: 0" ]]; then
    fail "$name (expected refusal with an untouched decoy, got: $out)"
    return
  fi
  pass "$name"
}

scenario_stalled_supervisor_does_not_hang_the_command() {
  local name="a stalled supervisor cannot hang the command"
  local root; root="$(fake_root stalled)"
  local dir; dir="$(pool_dir_for "$root")"
  started_pools+=("$dir")

  # Accept the connection and then say nothing, which is the shape of a wedged
  # supervisor. Without a deadline the wrapper blocks before the child starts.
  mkdir -p "$dir"
  chmod 700 "$dir"
  python3 - "$dir/sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(8)
held = []
while True:
    conn, _ = s.accept()
    held.append(conn)   # accepted, never answered
    time.sleep(0.1)
PY
  local silent=$!
  sleep 1

  local started elapsed seen
  started="$(date +%s)"
  seen="$(python3 "$JOBSERVER" run --repo-root "$root" --max 4 --env PROBE --floor 2 -- \
    "$PROBE_SCRIPT")"
  elapsed=$(($(date +%s) - started))
  kill -9 "$silent" 2>/dev/null
  wait "$silent" 2>/dev/null

  if [[ "$seen" != "2" ]]; then
    fail "$name (expected the floor width 2, got '$seen')"
    return
  fi
  if (( elapsed > 20 )); then
    fail "$name (took ${elapsed}s, so the handshake had no deadline)"
    return
  fi
  pass "$name"
}

scenario_run_propagates_exit_status() {
  local name="run propagates the command's exit status"
  local root; root="$(fake_root status)"
  track_pool "$root"
  python3 "$JOBSERVER" ensure --repo-root "$root" --budget 2 >/dev/null 2>&1

  local status=0
  python3 "$JOBSERVER" run --repo-root "$root" --max 1 --env PROBE -- sh -c 'exit 42' || status=$?
  if (( status != 42 )); then
    fail "$name (expected 42, got $status)"
    return
  fi
  pass "$name"
}

scenario_ensure_starts_pool_and_prints_makeflags
scenario_ensure_is_idempotent
scenario_run_exports_granted_width
scenario_grant_is_capped_by_budget
scenario_second_client_gets_the_remainder
scenario_sigkilled_client_returns_its_tokens
scenario_foreign_owned_pool_dir_is_refused
scenario_missing_pool_still_runs_the_command
scenario_run_preserves_argument_separators
scenario_lock_file_holds_only_the_current_pid
scenario_ensure_reports_the_running_budget
scenario_pool_location_ignores_the_user_variable
scenario_a_non_fifo_at_the_pool_path_is_replaced
scenario_acquire_surfaces_a_real_read_error
scenario_idle_exit_leaves_no_tokens_behind
scenario_partial_pool_keeps_its_tokens
scenario_signal_death_reports_a_shell_signal_status
scenario_split_request_is_still_granted
scenario_a_wiped_pool_does_not_wedge_its_successor
scenario_junk_at_either_runtime_path_is_cleared
scenario_restart_does_not_mint_a_second_budget
scenario_oversized_request_cannot_kill_the_pool
scenario_nonsense_widths_are_refused
scenario_cleanup_only_signals_a_supervisor
scenario_a_client_that_never_reads_cannot_wedge_the_pool
scenario_pipelined_requests_are_all_answered
scenario_symlinked_pool_parent_is_refused
scenario_stalled_supervisor_does_not_hang_the_command
scenario_run_propagates_exit_status

printf 'jobserver tests: %d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
