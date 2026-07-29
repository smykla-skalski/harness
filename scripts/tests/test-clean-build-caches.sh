#!/usr/bin/env bash
# Static coverage for clean-build-caches.sh targets that are easy to miss
# because they live in ignored repo-local build roots.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/clean-build-caches.sh"
# shellcheck source=scripts/lib/cargo-lane.sh
source "$ROOT/scripts/lib/cargo-lane.sh"

PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
TEST_TMP_ROOT=""
LIVE_LEASE_PIDS=()

log() {
  printf '%s\n' "$*" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  log "  FAIL: $CURRENT_TEST - $*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  log "  PASS: $CURRENT_TEST"
}

start_test() {
  CURRENT_TEST="$1"
  log "TEST: $CURRENT_TEST"
}

assert_contains() {
  local needle="$1"
  if grep -Fq -- "$needle" "$SCRIPT"; then
    return 0
  fi
  fail "expected clean-build-caches.sh to contain: $needle"
  return 1
}

cleanup() {
  local pid
  for pid in "${LIVE_LEASE_PIDS[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

reset_tmp_root() {
  [[ -n "$TEST_TMP_ROOT" ]] && rm -rf "$TEST_TMP_ROOT"
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clean-build-caches-test.XXXXXX")"
}

assert_output_line_contains() {
  local haystack="$1" path_needle="$2" marker="$3" line
  line="$(grep -m 1 -F -- "$path_needle" <<<"$haystack")" || {
    fail "expected output to contain a line for: $path_needle"
    return 1
  }
  grep -Fq -- "$marker" <<<"$line" || {
    fail "expected line for $path_needle to contain '$marker', got: $line"
    return 1
  }
}

assert_output_lacks() {
  local haystack="$1" needle="$2"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    fail "expected output NOT to mention: $needle"
    return 1
  fi
}

# kill -0 fails both when a PID is gone and when it belongs to another user
# we can't signal, so a live foreign-owned PID would look unused. ps -p
# reports existence without needing signal permission.
pid_exists() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" >/dev/null 2>&1
}

# A PID no process holds, found by probing upward from a value past any
# realistic pid_max rather than spawning and reaping a real process, since
# a just-freed PID can be reassigned before the lease file is read. Starts
# above the kernel's configured pid_max where that's exposed (Linux), since
# a raised pid_max can otherwise put 999999 inside the live range.
unused_pid() {
  local candidate=999999 pid_max
  if [[ -r /proc/sys/kernel/pid_max ]]; then
    pid_max="$(cat /proc/sys/kernel/pid_max 2>/dev/null || true)"
    if [[ "$pid_max" =~ ^[0-9]+$ ]] && (( pid_max >= candidate )); then
      candidate=$((pid_max + 1))
    fi
  fi
  while pid_exists "$candidate"; do
    candidate=$((candidate + 1))
  done
  printf '%s\n' "$candidate"
}

# Builds a fixture repo whose target/ mirrors the shared cargo-local.sh
# layout: the versioned main-checkout segment (a genuinely running
# background process holds its lease), a linked-worktree segment with a live
# lease, one with a dead lease (PID has already exited), one with no lease
# file at all, a stray top-level entry directly under target/ that predates
# the per-checkout scheme, a stray file directly under target/dev/ (not a
# segment directory), and an empty fake-home/ the caller can point HOME at
# so the script's global-cache section doesn't size the real
# $HOME/Library/Caches/*. Worktree segment and lease keys reuse
# cargo-local.sh's real wt-<worktree>-<hash>-v<format> shape so the fixture exercises
# dashes and digits in the match, not just plain words.
make_shared_target_fixture() {
  local repo="$1"
  local main_seg live_seg dead_seg nolease_seg
  main_seg="$(cargo_lane_main_segment)"
  live_seg="wt-live-0e4eb0f4-v$HARNESS_CARGO_LANE_FORMAT_VERSION"
  dead_seg="wt-dead-1a2b3c4d-v$HARNESS_CARGO_LANE_FORMAT_VERSION"
  nolease_seg="wt-nolease-3f4e5d6c-v$HARNESS_CARGO_LANE_FORMAT_VERSION"
  mkdir -p "$repo/scripts/lib"
  mkdir -p "$repo/fake-home"
  cp "$SCRIPT" "$repo/scripts/clean-build-caches.sh"
  cp "$ROOT/scripts/sccache-cleanup-audit.py" "$repo/scripts/sccache-cleanup-audit.py"
  cp "$ROOT/scripts/lib/sccache_processes.py" "$repo/scripts/lib/sccache_processes.py"
  cp "$ROOT/scripts/lib/common-repo-root.sh" "$repo/scripts/lib/common-repo-root.sh"
  cp "$ROOT/scripts/lib/cargo-lane.sh" "$repo/scripts/lib/cargo-lane.sh"

  mkdir -p "$repo/target/dev/$main_seg/debug"
  mkdir -p "$repo/target/dev/$live_seg/debug"
  mkdir -p "$repo/target/dev/$dead_seg/debug"
  mkdir -p "$repo/target/dev/$nolease_seg/debug"
  echo "obj" > "$repo/target/dev/$main_seg/debug/harness"
  echo "obj" > "$repo/target/dev/$live_seg/debug/harness"
  echo "obj" > "$repo/target/dev/$dead_seg/debug/harness"
  echo "obj" > "$repo/target/dev/$nolease_seg/debug/harness"
  echo "stray" > "$repo/target/stray-legacy-artifact"
  echo "stray" > "$repo/target/dev/.rustc_info.json"

  mkdir -p "$repo/target/.cargo-local/leases"
  local local_pid
  sleep 300 &
  local_pid=$!
  LIVE_LEASE_PIDS+=("$local_pid")
  printf '%s\n' "$local_pid" > "$repo/target/.cargo-local/leases/$main_seg-$local_pid"

  local wt_live_pid
  sleep 300 &
  wt_live_pid=$!
  LIVE_LEASE_PIDS+=("$wt_live_pid")
  printf '%s\n' "$wt_live_pid" \
    > "$repo/target/.cargo-local/leases/$live_seg-$wt_live_pid"

  local dead_pid
  dead_pid="$(unused_pid)"
  printf '%s\n' "$dead_pid" \
    > "$repo/target/.cargo-local/leases/$dead_seg-$dead_pid"
}

scenario_dry_run_keeps_leased_segment() {
  start_test "dry-run keeps a segment with a live cargo-local.sh lease"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output="" main_seg live_seg dead_seg nolease_seg
  main_seg="$(cargo_lane_main_segment)"
  live_seg="wt-live-0e4eb0f4-v$HARNESS_CARGO_LANE_FORMAT_VERSION"
  dead_seg="wt-dead-1a2b3c4d-v$HARNESS_CARGO_LANE_FORMAT_VERSION"
  nolease_seg="wt-nolease-3f4e5d6c-v$HARNESS_CARGO_LANE_FORMAT_VERSION"

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp"
  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    ./scripts/clean-build-caches.sh --dry-run)"

  assert_output_line_contains "$output" "target/dev/$main_seg" "(active build, kept)"
  assert_output_line_contains "$output" "target/dev/$live_seg" "(active build, kept)"
  assert_output_line_contains "$output" "target/dev/$dead_seg" "(dry-run)"
  assert_output_line_contains "$output" "target/dev/$nolease_seg" "(dry-run)"
  assert_output_line_contains "$output" "target/stray-legacy-artifact" "(dry-run)"
  assert_output_line_contains "$output" "target/dev/.rustc_info.json" "(dry-run)"
  pass
}

# Builds a fake TMPDIR holding the shapes the sweep has to tell apart: a
# leaked test temp dir old enough to reclaim, one young enough that a running
# suite may still hold it, one whose own mtime is old but whose contents are
# live (a long suite that writes deep inside without touching the top level),
# the reusable agent probe home that must survive because tests share it, and
# an unrelated directory the sweep must never consider, plus a six-character name
# holding a space to prove the selector demands alphanumerics: the sweep's
# line-oriented set arithmetic breaks on a name containing a newline, so a `?`
# wildcard there would be a latent bug. Old timestamps use a fixed date far in
# the past rather than date arithmetic, which differs between BSD and GNU date,
# and stay old on any plausible system clock. Every fixture name carries exactly
# six characters after `.tmp` because that is what the tempfile crate emits and
# what the sweep matches; a five-character name falls outside it entirely.
make_stale_tmp_fixture() {
  local tmp="$1"
  mkdir -p "$tmp"

  mkdir -p "$tmp/.tmpstale1"
  echo "leaked" > "$tmp/.tmpstale1/payload"
  touch -t 200001010000 "$tmp/.tmpstale1/payload" "$tmp/.tmpstale1"

  mkdir -p "$tmp/.tmpfresh1"
  echo "in use" > "$tmp/.tmpfresh1/payload"

  mkdir -p "$tmp/.tmpbusy01/nested"
  echo "still writing" > "$tmp/.tmpbusy01/nested/payload"
  touch -t 200001010000 "$tmp/.tmpbusy01"

  mkdir -p "$tmp/harness-agent-probe-home/Library/Caches/copilot"
  touch -t 200001010000 "$tmp/harness-agent-probe-home"

  mkdir -p "$tmp/not-a-temp-dir"
  touch -t 200001010000 "$tmp/not-a-temp-dir"

  mkdir -p "$tmp/.tmp ab123"
  touch -t 200001010000 "$tmp/.tmp ab123"
}

scenario_dry_run_sweeps_only_stale_test_temp_dirs() {
  start_test "dry-run reclaims stale .tmp dirs and keeps live ones"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local faketmp="$TEST_TMP_ROOT/faketmp"
  local output=""

  make_shared_target_fixture "$repo"
  make_stale_tmp_fixture "$faketmp"

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$faketmp" \
    ./scripts/clean-build-caches.sh --dry-run)"

  assert_output_line_contains "$output" "stale .tmp dirs (1)" "(dry-run)" || return
  assert_output_line_contains "$output" "recent .tmp dirs kept (2)" "-" || return
  assert_output_lacks "$output" "not-a-temp-dir" || return
  assert_output_lacks "$output" "harness-agent-probe-home" || return
  pass
}

scenario_missing_common_repo_root_lib_aborts_safely() {
  start_test "missing common-repo-root.sh aborts instead of computing a wrong path"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output="" status=0

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp"
  rm -f "$repo/scripts/lib/common-repo-root.sh"

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    ./scripts/clean-build-caches.sh --dry-run 2>&1)" || status=$?

  if (( status == 0 )); then
    fail "expected a nonzero exit when common-repo-root.sh is missing, got 0"
    return
  fi
  grep -Fq "failed to source scripts/lib/common-repo-root.sh" <<<"$output" || {
    fail "expected the failure message in output, got: $output"
    return
  }
  if grep -Fq "== clean-build-caches ==" <<<"$output"; then
    fail "expected the script to abort before printing its normal banner"
    return
  fi
  pass
}

scenario_includes_daemon_cargo_target() {
  start_test "daemon cargo target is a clean:caches target"
  assert_contains "remove_path 'daemon cargo target'" || return
  assert_contains "\"\$ROOT/.cache/harness-monitor-xcode-daemon\"" || return
  pass
}

scenario_includes_all_repo_rust_target_roots() {
  start_test "repo Rust target search includes apps, crates, and mcp-servers"
  assert_contains "\"\$ROOT/apps\" \"\$ROOT/crates\" \"\$ROOT/mcp-servers\"" || return
  assert_contains "-type d -name target -prune -print0" || return
  pass
}

scenario_includes_all_project_xcode_roots() {
  start_test "project-local Xcode derived roots are explicit targets"
  assert_contains "remove_path 'xcode-derived/'" || return
  assert_contains "remove_path 'xcode-derived-e2e/'" || return
  assert_contains "remove_path 'xcode-derived-lanes/'" || return
  assert_contains "remove_path 'xcode-derived-instruments/'" || return
  pass
}

scenario_includes_swiftpm_build_roots() {
  start_test "SwiftPM .build search covers apps and mcp-servers"
  assert_contains "section 'SwiftPM artifacts (project-local)'" || return
  assert_contains "\"\$ROOT/apps\" \"\$ROOT/mcp-servers\"" || return
  assert_contains "-type d -name '.build' -prune -print0" || return
  pass
}

scenario_includes_scope_comment() {
  start_test "default scope documents the ignored build roots"
  assert_contains ".cache/harness-monitor-xcode-daemon" || return
  assert_contains "Repo SwiftPM artifacts" || return
  pass
}

scenario_sccache_is_gated_not_unconditional() {
  start_test "sccache removal is gated, not unconditional remove_path"
  # The old script ran `remove_path 'Mozilla.sccache'` directly under the
  # global-caches section, wiping a warm cache on every clean:caches. The gate
  # routes through clean_sccache_caches instead, and the unconditional lines
  # must be gone or a size gate is meaningless.
  assert_contains 'clean_sccache_caches' || return
  assert_contains 'stop_repo_sccache_server' || return
  assert_contains 'SCCACHE_REMOVE_THRESHOLD_KB' || return
  assert_contains '100 * 1024 * 1024' || return
  # The threshold compares total_kb against it; `>` not `>=`, so exactly 100G
  # is kept and 100G + 1K is removed.
  assert_contains 'total_kb > SCCACHE_REMOVE_THRESHOLD_KB' || return
  if grep -Fq "remove_path 'Mozilla.sccache'" "$SCRIPT"; then
    fail "unconditional remove_path 'Mozilla.sccache' still present; gate is bypassable"
    return 1
  fi
  pass
}

scenario_sccache_covers_linux_cache_path() {
  start_test "sccache cache list includes the Linux ~/.cache/sccache path"
  # The macOS pair (Library/Caches/Mozilla.sccache, Library/Caches/sccache) was
  # already listed; the Linux default ~/.cache/sccache was missing entirely, so
  # clean:caches never reclaimed sccache on Linux.
  assert_contains "\"\$HOME/.cache/sccache\"" || return
  pass
}

scenario_force_help_mentions_sccache() {
  start_test "--force help text documents that it also removes sccache"
  assert_contains 'Also remove sccache and ms-playwright caches' || return
  assert_contains 'sccache auto-removes over 100G' || return
  pass
}

# Regression for the original bug: clean:caches deleted the sccache cache dir
# out from under the running server, turning every later compile into a write
# error. A healthy cache must survive a default dry-run and report as kept.
scenario_dry_run_keeps_small_sccache_cache() {
  start_test "dry-run keeps a small sccache cache (under 100G threshold)"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output=""

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp"
  # A small warm cache under the isolated fake-home; size is well under 100G,
  # so the gate must keep it rather than mark it for removal.
  mkdir -p "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    ./scripts/clean-build-caches.sh --dry-run)" || { fail "dry-run exited non-zero: $output"; return 1; }

  assert_output_line_contains "$output" "Library/Caches/Mozilla.sccache" "(dry-run, kept" || return
  # Kept, not slated for removal: the must-remove marker is absent from the line.
  if grep -F "Library/Caches/Mozilla.sccache" <<<"$output" | grep -Fq 'would remove'; then
    fail "small sccache cache marked for removal under the 100G threshold"
    return 1
  fi
  pass
}

scenario_normal_cleanup_keeps_small_sccache_cache_and_live_server() {
  start_test "normal cleanup keeps a small sccache cache and does not stop its server"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local stop_log="$TEST_TMP_ROOT/stop.log"

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp" "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"
  cat > "$repo/scripts/cargo-local.sh" <<CARGO_LOCAL
#!/usr/bin/env bash
printf 'SCCACHE_BIN=%s\n' "$repo/fake-bin/sccache"
printf 'SCCACHE_SERVER_UDS=%s\n' "$repo/fake-tmp/live.sock"
CARGO_LOCAL
  mkdir -p "$repo/fake-bin"
  cat > "$repo/fake-bin/sccache" <<CARGO_CACHE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$stop_log"
CARGO_CACHE
  chmod +x "$repo/scripts/cargo-local.sh" "$repo/fake-bin/sccache"
  python3 - "$repo/fake-tmp/live.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY

  (cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    PATH="/usr/bin:/bin" ./scripts/clean-build-caches.sh >/dev/null)

  [[ -e "$repo/fake-home/Library/Caches/Mozilla.sccache/blob" ]] || {
    fail "normal cleanup removed the below-threshold cache"
    return
  }
  [[ ! -e "$stop_log" ]] || {
    fail "normal cleanup stopped the server despite keeping its cache"
    return
  }
  [[ ! -e "$repo/.cache/diagnostics/sccache-cleanup.jsonl" ]] || {
    fail "non-destructive cleanup wrote a destructive audit event"
    return
  }
  pass
}

scenario_destructive_dry_run_is_write_free() {
  start_test "destructive dry-run reports attribution without writing or deleting"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output=""

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp" "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    PATH="/usr/bin:/bin" ./scripts/clean-build-caches.sh --dry-run --force)"

  [[ -e "$repo/fake-home/Library/Caches/Mozilla.sccache/blob" ]] || {
    fail "dry-run deleted the cache"
    return
  }
  [[ ! -e "$repo/.cache/diagnostics/sccache-cleanup.jsonl" ]] || {
    fail "dry-run wrote the audit log"
    return
  }
  grep -Fq 'audit preview:' <<<"$output" || {
    fail "dry-run omitted the audit preview: $output"
    return
  }
  grep -Fq '"reason":"--force"' <<<"$output" || {
    fail "dry-run preview omitted the removal reason: $output"
    return
  }
  pass
}

# Regression for a Copilot finding: if the sccache server cannot be stopped,
# the cache must be kept even under --force, because deleting it under a live
# server is the exact write-error failure mode this script exists to prevent.
# Simulated by pointing SCCACHE_BIN at a fake binary that fails --stop-server
# while a real Unix socket satisfies the [[ -S ]] guard, so the stop path is
# taken and fails.
scenario_keeps_cache_when_stop_fails_even_under_force() {
  start_test "sccache cache kept under --force when the server fails to stop"
  if ! command -v python3 >/dev/null 2>&1; then
    log "  SKIP: python3 unavailable to create a test socket"
    pass
    return
  fi
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output=""

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp" "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"

  # A fake stop binary that is executable and always exits non-zero. The guard
  # checks [[ -x "$bin" ]], so it has to be a real executable on disk.
  local fake_bin="$repo/fake-bin/sccache-stop"
  mkdir -p "$repo/fake-bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fake_bin"
  chmod +x "$fake_bin"

  # A fake cargo-local.sh whose --print-env names the failing binary and a real
  # socket path. stop_repo_sccache_server calls this to resolve SCCACHE_BIN/UDS.
  local socket="$repo/fake-tmp/fake-socket.sock"
  cat > "$repo/scripts/cargo-local.sh" <<CARGO_LOCAL
#!/usr/bin/env bash
case "\${1:-}\${2:-}" in
  --print-env)
    printf 'SCCACHE_BIN=%s\n' "$fake_bin"
    printf 'SCCACHE_SERVER_UDS=%s\n' "$socket"
    ;;
esac
CARGO_LOCAL
  chmod +x "$repo/scripts/cargo-local.sh"
  # Bind a real Unix socket so [[ -S ]] passes and the stop path actually runs.
  python3 - "$socket" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
PY

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    ./scripts/clean-build-caches.sh --force 2>&1)" || true

  # The stop must warn, and the cache must survive despite --force.
  grep -Fq 'sccache --stop-server failed' <<<"$output" || { fail "expected stop-failure warning, got: $output"; return 1; }
  if [[ ! -e "$repo/fake-home/Library/Caches/Mozilla.sccache/blob" ]]; then
    fail "cache removed under --force despite a failed server stop"
    return 1
  fi
  local audit="$repo/.cache/diagnostics/sccache-cleanup.jsonl"
  [[ -s "$audit" ]] || {
    fail "failed stop did not leave an audit event"
    return 1
  }
  grep -Fq '"stop_outcome":"failed"' "$audit" || {
    fail "failed stop audit omitted its outcome: $(<"$audit")"
    return 1
  }
  pass
}

scenario_authorized_removal_is_audited_before_cache_deletion() {
  start_test "authorized sccache removal leaves durable attribution"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp" "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"

  (cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    PATH="/usr/bin:/bin" ./scripts/clean-build-caches.sh --force >/dev/null)

  [[ ! -e "$repo/fake-home/Library/Caches/Mozilla.sccache" ]] || {
    fail "authorized removal left the cache behind"
    return
  }
  local audit="$repo/.cache/diagnostics/sccache-cleanup.jsonl"
  [[ -s "$audit" ]] || {
    fail "authorized removal produced no audit event"
    return
  }
  local required
  for required in timestamp mode cache_paths measured_size_kb reason threshold_kb \
    server_socket server_pids stop_outcome; do
    grep -Fq "\"$required\":" "$audit" || {
      fail "audit omitted $required: $(<"$audit")"
      return
    }
  done
  grep -Fq '"reason":"--force"' "$audit" || {
    fail "audit omitted force attribution: $(<"$audit")"
    return
  }
  pass
}

# Regression for a Copilot finding: two candidate paths that resolve to the same
# physical directory must be deduped, so a symlinked Caches cannot produce two
# per-dir lines for one cache. The observable invariant is the per-dir line
# count: two aliasing candidates print one line, not two. (du -sk on a symlink
# to a directory reports 0, so size alone would not prove dedup.)
scenario_dedupes_symlinked_sccache_cache_dirs() {
  start_test "symlinked sccache cache dirs are deduped to their physical path"
  reset_tmp_root
  local repo="$TEST_TMP_ROOT/repo"
  local output="" per_dir_lines

  make_shared_target_fixture "$repo"
  mkdir -p "$repo/fake-tmp" "$repo/fake-home/Library/Caches/Mozilla.sccache"
  echo "cached object" > "$repo/fake-home/Library/Caches/Mozilla.sccache/blob"
  # Make the second macOS path a symlink to the first, so both candidates
  # resolve to one physical directory.
  ln -s "$repo/fake-home/Library/Caches/Mozilla.sccache" "$repo/fake-home/Library/Caches/sccache"

  output="$(cd "$repo" && HOME="$repo/fake-home" TMPDIR="$repo/fake-tmp" \
    ./scripts/clean-build-caches.sh --dry-run 2>&1)" || { fail "dry-run exited non-zero: $output"; return 1; }

  # Count the per-dir lines: they list the resolved relative paths and skip the
  # 'total' summary line. Two aliasing candidates must collapse to one line.
  per_dir_lines="$(grep -Fc 'Library/Caches/' <<<"$(grep -Fv 'total' <<<"$output")")"
  if [[ "$per_dir_lines" != "1" ]]; then
    fail "symlinked dir not deduped: expected 1 per-dir line, got $per_dir_lines: $output"
    return 1
  fi
  pass
}

scenario_dry_run_keeps_leased_segment
scenario_dry_run_sweeps_only_stale_test_temp_dirs
scenario_missing_common_repo_root_lib_aborts_safely
scenario_includes_daemon_cargo_target
scenario_includes_all_repo_rust_target_roots
scenario_includes_all_project_xcode_roots
scenario_includes_swiftpm_build_roots
scenario_includes_scope_comment
scenario_sccache_is_gated_not_unconditional
scenario_sccache_covers_linux_cache_path
scenario_force_help_mentions_sccache
scenario_dry_run_keeps_small_sccache_cache
scenario_normal_cleanup_keeps_small_sccache_cache_and_live_server
scenario_destructive_dry_run_is_write_free
scenario_keeps_cache_when_stop_fails_even_under_force
scenario_authorized_removal_is_audited_before_cache_deletion
scenario_dedupes_symlinked_sccache_cache_dirs

log "clean-build-caches tests: $PASS_COUNT passed, $FAIL_COUNT failed"
if (( FAIL_COUNT > 0 )); then
  exit 1
fi
