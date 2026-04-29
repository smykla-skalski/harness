#!/bin/bash

# shellcheck source=apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/swift-tool-env.sh"
sanitize_xcode_only_swift_environment

run_xcodebuild_command() {
  local xcodebuild_bin="${XCODEBUILD_BIN:-/usr/bin/xcodebuild}"
  if [[ ! -x "$xcodebuild_bin" ]]; then
    echo "xcodebuild binary is not executable: $xcodebuild_bin" >&2
    return 127
  fi
  "$xcodebuild_bin" "$@"
}

# Run `tuist xcodebuild` from the Tuist project root so its module-hash cache
# kicks in (selective testing skips unchanged test targets transparently).
# Required env: HARNESS_MONITOR_APP_ROOT must point at apps/harness-monitor-macos.
run_tuist_xcodebuild_command() {
  local app_root="${HARNESS_MONITOR_APP_ROOT:-}"
  local tuist_bin
  if [[ -z "$app_root" || ! -d "$app_root" ]]; then
    echo "run_tuist_xcodebuild_command: HARNESS_MONITOR_APP_ROOT is not set or missing" >&2
    return 1
  fi
  tuist_bin="$(type -P tuist || true)"
  if [[ -z "$tuist_bin" ]]; then
    echo "run_tuist_xcodebuild_command: tuist is required for all Harness Monitor xcodebuild wrapper lanes; pin it in .mise.toml" >&2
    return 127
  fi
  (
    cd "$app_root" || exit 1
    run_with_sanitized_xcode_only_swift_environment "$tuist_bin" xcodebuild "$@"
  )
}

launch_xcodebuild_command_capture() {
  local captured_log_path="$1"
  shift
  local use_tuist="$1"
  shift
  RUN_XCODEBUILD_CAPTURE_PID=""

  if (( use_tuist == 1 )); then
    local app_root="${HARNESS_MONITOR_APP_ROOT:-}"
    local tuist_bin
    if [[ -z "$app_root" || ! -d "$app_root" ]]; then
      echo "launch_xcodebuild_command_capture: HARNESS_MONITOR_APP_ROOT is not set or missing" >&2
      return 1
    fi
    tuist_bin="$(type -P tuist || true)"
    if [[ -z "$tuist_bin" ]]; then
      echo "launch_xcodebuild_command_capture: tuist is required for all Harness Monitor xcodebuild wrapper lanes; pin it in .mise.toml" >&2
      return 127
    fi

    (
      cd "$app_root" || exit 1
      exec env \
        -u SWIFT_DEBUG_INFORMATION_FORMAT \
        -u SWIFT_DEBUG_INFORMATION_VERSION \
        "$tuist_bin" xcodebuild "$@"
    ) >"$captured_log_path" 2>&1 &
    RUN_XCODEBUILD_CAPTURE_PID="$!"
    return 0
  fi

  local xcodebuild_bin="${XCODEBUILD_BIN:-/usr/bin/xcodebuild}"
  if [[ ! -x "$xcodebuild_bin" ]]; then
    echo "xcodebuild binary is not executable: $xcodebuild_bin" >&2
    return 127
  fi
  "$xcodebuild_bin" "$@" >"$captured_log_path" 2>&1 &
  RUN_XCODEBUILD_CAPTURE_PID="$!"
}

xcbeautify_is_disabled() {
  case "${HARNESS_MONITOR_DISABLE_XCBEAUTIFY:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Run xcodebuild and pipe its combined stdout/stderr through xcbeautify when
# available. Falls back to plain xcodebuild output when xcbeautify is missing,
# so callers stay resilient on hosts that have not provisioned the tool yet.
#
# Optional leading flags consumed by this wrapper (must come BEFORE xcodebuild args):
#   --junit-path <file>   Tell xcbeautify to emit a JUnit report at <file>.
#   --use-tuist           Route the xcodebuild invocation through `tuist xcodebuild`
#                         so Tuist's local hash cache enables selective testing.
#
# The exit status is the xcodebuild status (PIPESTATUS[0]).
run_xcodebuild_with_formatter() {
  local junit_path=""
  local use_tuist=0
  local raw_log_path="${XCODEBUILD_RAW_LOG_PATH:-}"
  local captured_log_path=""
  local cleanup_captured_log=0
  local xcodebuild_pid xcodebuild_status formatter_status
  while (( $# > 0 )); do
    case "$1" in
      --junit-path)
        if (( $# < 2 )); then
          echo "run_xcodebuild_with_formatter: --junit-path requires a value" >&2
          return 1
        fi
        junit_path="$2"
        shift 2
        ;;
      --use-tuist)
        use_tuist=1
        shift
        ;;
      *) break ;;
    esac
  done

  if [[ -n "$raw_log_path" ]]; then
    captured_log_path="$raw_log_path"
  else
    captured_log_path="$(mktemp "${TMPDIR:-/tmp}/harness-monitor-xcodebuild.XXXXXX.log")"
    cleanup_captured_log=1
  fi

  if ! launch_xcodebuild_command_capture "$captured_log_path" "$use_tuist" "$@"; then
    local launch_status="$?"
    if (( cleanup_captured_log == 1 )); then
      /bin/rm -f "$captured_log_path"
    fi
    return "$launch_status"
  fi
  xcodebuild_pid="$RUN_XCODEBUILD_CAPTURE_PID"

  set +e
  wait "$xcodebuild_pid"
  xcodebuild_status="$?"
  set -e

  if ! xcbeautify_is_disabled && command -v xcbeautify >/dev/null 2>&1; then
    local -a xcb_args=(--renderer terminal --is-ci --disable-logging)
    if [[ -n "$junit_path" ]]; then
      /bin/mkdir -p "$(dirname "$junit_path")"
      xcb_args+=(--report junit --report-path "$junit_path")
    fi
    set +e
    xcbeautify "${xcb_args[@]}" <"$captured_log_path"
    formatter_status="$?"
    set -e
    if (( formatter_status != 0 )); then
      cat "$captured_log_path"
    fi
  else
    cat "$captured_log_path"
  fi

  if (( cleanup_captured_log == 1 )); then
    /bin/rm -f "$captured_log_path"
  fi

  return "$xcodebuild_status"
}

# Returns 0 when the xcodebuild arg list contains a test action, 1 otherwise.
# Used by xcodebuild-with-lock.sh to decide whether to enable native test
# retry flags and JUnit reporting.
xcodebuild_args_are_test_action() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      test|test-without-building) return 0 ;;
    esac
  done
  return 1
}

# Returns 0 when the arg list already contains the given xcodebuild flag.
xcodebuild_args_have_flag() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

print_log_tail_compact() {
  local lines="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  /usr/bin/tail -n "$lines" "$path"
}

descendant_process_pids() {
  local root_pid="$1"
  /bin/ps -Ao pid=,ppid= \
    | /usr/bin/awk -v root_pid="$root_pid" '
        {
          pid = $1
          ppid = $2
          children[ppid] = children[ppid] " " pid
        }

        function walk(parent_pid, child_list, child_count, child_index, child_pid) {
          child_count = split(children[parent_pid], child_list, " ")
          for (child_index = 1; child_index <= child_count; child_index += 1) {
            child_pid = child_list[child_index]
            if (child_pid == "") {
              continue
            }
            print child_pid
            walk(child_pid)
          }
        }

        END {
          walk(root_pid)
        }
      '
}

terminate_descendant_processes() {
  local root_pid="$1"
  local signal="${2:-TERM}"
  local -a descendant_pids=()
  local descendant_pid
  local index

  while IFS= read -r descendant_pid; do
    if [[ -n "$descendant_pid" ]]; then
      descendant_pids+=("$descendant_pid")
    fi
  done < <(descendant_process_pids "$root_pid")
  if (( ${#descendant_pids[@]} == 0 )); then
    return 0
  fi

  for ((index = ${#descendant_pids[@]} - 1; index >= 0; index -= 1)); do
    kill "-${signal}" "${descendant_pids[index]}" 2>/dev/null || true
  done

  if [[ "$signal" != "KILL" ]]; then
    sleep 0.2
    for ((index = ${#descendant_pids[@]} - 1; index >= 0; index -= 1)); do
      if kill -0 "${descendant_pids[index]}" 2>/dev/null; then
        kill -KILL "${descendant_pids[index]}" 2>/dev/null || true
      fi
    done
  fi
}
