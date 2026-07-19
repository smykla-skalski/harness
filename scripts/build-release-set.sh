#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-set.sh
source "$ROOT/scripts/lib/release-set.sh"
if (( $# > 0 )); then
  selectors=("$@")
else
  selectors=(all)
fi
cd "$ROOT"

if (( ${#HARNESS_RELEASE_BINARIES[@]} != ${#HARNESS_RELEASE_BUILD_LEAVES[@]} )); then
  printf 'release inventory and build-leaf mapping are out of sync\n' >&2
  exit 2
fi

if ! release_set_resolve_selectors "${selectors[@]}"; then
  printf 'usage: %s [<selector>...]\n' "${0##*/}" >&2
  printf 'selector: all, harness, aff, or a leaf (harness-cli, daemon, systemd, bridge, mcp, hook, codex, openrouter)\n' >&2
  exit 2
fi
scope="${selectors[*]}"

resolve_target_dir() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    printf '%s\n' "$CARGO_TARGET_DIR"
    return 0
  fi

  "$ROOT/scripts/cargo-local.sh" --print-env \
    | command awk -F= '/^CARGO_TARGET_DIR=/{print $2}'
}

target_dir="$(resolve_target_dir)"
if [[ -z "$target_dir" ]]; then
  printf 'failed to resolve CARGO_TARGET_DIR\n' >&2
  exit 1
fi
target_dir="$(release_normalize_target_dir "$target_dir")"
export CARGO_TARGET_DIR="$target_dir"

job_cap="${CARGO_BUILD_JOBS:-${HARNESS_CARGO_JOBS:-1}}"
if [[ ! "$job_cap" =~ ^[0-9]+$ ]] || (( job_cap < 1 )); then
  printf 'CARGO_BUILD_JOBS must be a positive integer (got %s)\n' "$job_cap" >&2
  exit 2
fi

state_root="${HARNESS_RELEASE_BUILD_STATE_DIR:-$target_dir/.release-build}"
log_root="${HARNESS_RELEASE_BUILD_LOG_DIR:-$state_root/logs}"
invocation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM:-0}"
log_dir="$log_root/$invocation_id"
build_root="${HARNESS_RELEASE_BUILD_DIR:-$state_root/build}"
trace_path="${HARNESS_RELEASE_BUILD_TRACE:-}"
publish_dir="$state_root/publish/$invocation_id"
mkdir -p "$log_dir" "$build_root"

leaf_names=("${RELEASE_SET_SELECTED_LEAVES[@]}")
binary_names=("${RELEASE_SET_SELECTED_BINARIES[@]}")
leaf_count=${#leaf_names[@]}

if (( leaf_count != ${#binary_names[@]} )); then
  printf 'release build leaves and binaries are out of sync\n' >&2
  exit 2
fi

if (( job_cap < leaf_count )); then
  max_parallel=$job_cap
else
  max_parallel=$leaf_count
fi

leaf_jobs=()
for ((index = 0; index < leaf_count; index++)); do
  leaf_jobs+=(1)
done

if (( leaf_count == 1 )); then
  leaf_jobs[0]=$job_cap
elif (( job_cap > leaf_count )); then
  extra_jobs=$((job_cap - leaf_count))
  extra_index=0
  while (( extra_jobs > 0 )); do
    leaf_jobs[extra_index]=$((leaf_jobs[extra_index] + 1))
    extra_jobs=$((extra_jobs - 1))
    extra_index=$(((extra_index + 1) % leaf_count))
  done
fi

pids=()
logs=()
for ((index = 0; index < leaf_count; index++)); do
  pids+=("")
  logs+=("$log_dir/${leaf_names[index]}.log")
  : >"$log_dir/${leaf_names[index]}.log"
done
next_leaf=0
active_count=0

trace_event() {
  [[ -n "$trace_path" ]] || return 0
  printf '%s\n' "$*" >>"$trace_path"
}

start_leaf() {
  local index="$1"
  local name="${leaf_names[index]}"
  local jobs="${leaf_jobs[index]}"
  local build_dir="$build_root/$name"
  local log_path="${logs[index]}"

  mkdir -p "$build_dir"
  : >"$log_path"
  trace_event "start leaf=$name jobs=$jobs build_dir=$build_dir log=$log_path"

  (
    export CARGO_TARGET_DIR="$build_dir"
    unset CARGO_BUILD_BUILD_DIR
    export CARGO_BUILD_JOBS="$jobs"
    export HARNESS_CARGO_GROUP_CHILD=1
    export HARNESS_CARGO_SKIP_LEASE=1
    export HARNESS_RELEASE_BUILD_LEAF="$name"
    export HARNESS_RELEASE_OUTPUT_TARGET_DIR="$target_dir"
    case "$name" in
      harness)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness --bin harness
        ;;
      daemon)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness-daemon --bin harness-daemon \
          --features tokio-console
        ;;
      systemd)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness-systemd --bin harness-systemd
        ;;
      bridge)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness-bridge --bin harness-bridge
        ;;
      mcp)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness-mcp --bin harness-mcp
        ;;
      hook)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked -p harness-hook --bin harness-hook
        ;;
      codex)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked \
          --manifest-path crates/harness-codex-acp/Cargo.toml
        ;;
      openrouter)
        exec "$ROOT/scripts/cargo-local.sh" \
          build --release --locked \
          --manifest-path crates/harness-openrouter-agent/Cargo.toml
        ;;
      aff)
        exec "$ROOT/scripts/cargo-local.sh" build --release --locked -p aff --bin aff
        ;;
    esac
  ) >"$log_path" 2>&1 &

  pids[index]=$!
  active_count=$((active_count + 1))
  printf 'release build: started %s (%s job(s), log: %s)\n' \
    "$name" "$jobs" "$log_path"
}

publish_build_artifacts() {
  local index source staged destination

  command rm -rf "$publish_dir"
  command mkdir -p "$publish_dir" "$target_dir/release"
  for ((index = 0; index < leaf_count; index++)); do
    source="$build_root/${leaf_names[index]}/release/${binary_names[index]}"
    staged="$publish_dir/${binary_names[index]}"
    if [[ ! -x "$source" ]]; then
      printf 'release build did not produce executable %s\n' "$source" >&2
      return 1
    fi
    command cp -p "$source" "$staged"
  done

  for ((index = 0; index < leaf_count; index++)); do
    staged="$publish_dir/${binary_names[index]}"
    destination="$target_dir/release/${binary_names[index]}"
    command mv -f "$staged" "$destination"
  done
  command rmdir "$publish_dir"
}

process_is_running() {
  local pid="$1"
  local state
  state="$(command ps -p "$pid" -o stat= 2>/dev/null || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

signal_process_tree() {
  local signal="$1"
  local pid="$2"
  local child
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(command pgrep -P "$pid" 2>/dev/null || true); do
      signal_process_tree "$signal" "$child"
    done
  fi
  command kill "-$signal" "$pid" 2>/dev/null || true
}

cancel_active_leaves() {
  local keep_index="${1:--1}"
  local index pid attempt

  for ((index = 0; index < leaf_count; index++)); do
    pid="${pids[index]}"
    [[ -n "$pid" ]] || continue
    (( index == keep_index )) && continue
    signal_process_tree TERM "$pid"
  done

  for ((attempt = 0; attempt < 30; attempt++)); do
    local any_running=0
    for ((index = 0; index < leaf_count; index++)); do
      pid="${pids[index]}"
      [[ -n "$pid" ]] || continue
      (( index == keep_index )) && continue
      if process_is_running "$pid"; then
        any_running=1
      fi
    done
    (( any_running == 0 )) && break
    sleep 0.1
  done

  for ((index = 0; index < leaf_count; index++)); do
    pid="${pids[index]}"
    [[ -n "$pid" ]] || continue
    (( index == keep_index )) && continue
    if process_is_running "$pid"; then
      signal_process_tree KILL "$pid"
    fi
    wait "$pid" 2>/dev/null || true
    pids[index]=""
  done
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  cancel_active_leaves
  command rm -rf "$publish_dir"
  release_pipeline_lock_release
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release_pipeline_lock_acquire "$target_dir"

while (( next_leaf < leaf_count || active_count > 0 )); do
  while (( next_leaf < leaf_count && active_count < max_parallel )); do
    start_leaf "$next_leaf"
    next_leaf=$((next_leaf + 1))
    if [[ "${HARNESS_RELEASE_BUILD_TEST_EXIT_AFTER_STARTS:-}" == "$next_leaf" ]]; then
      sleep "${HARNESS_RELEASE_BUILD_TEST_EXIT_DELAY_SECONDS:-0}"
      printf 'injected release coordinator exit\n' >&2
      exit 91
    fi
  done

  completed_any=0
  for ((index = 0; index < leaf_count; index++)); do
    pid="${pids[index]}"
    [[ -n "$pid" ]] || continue
    if process_is_running "$pid"; then
      continue
    fi

    status=0
    wait "$pid" || status=$?
    pids[index]=""
    active_count=$((active_count - 1))
    completed_any=1
    name="${leaf_names[index]}"
    trace_event "finish leaf=$name status=$status"

    if (( status != 0 )); then
      cancel_active_leaves "$index"
      printf 'release build: %s failed with status %s; log retained at %s\n' \
        "$name" "$status" "${logs[index]}" >&2
      command cat "${logs[index]}" >&2
      exit "$status"
    fi
    printf 'release build: finished %s\n' "$name"
  done

  if (( completed_any == 0 )); then
    sleep 0.1
  fi
done

publish_build_artifacts

printf 'release build: completed %s set with shared cap %s (logs: %s)\n' \
  "$scope" "$job_cap" "$log_dir"
