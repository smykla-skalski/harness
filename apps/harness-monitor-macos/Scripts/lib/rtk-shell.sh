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
    echo "run_tuist_xcodebuild_command: tuist is not on PATH; pin it in .mise.toml" >&2
    return 127
  fi
  (
    cd "$app_root" || exit 1
    run_with_sanitized_xcode_only_swift_environment "$tuist_bin" xcodebuild "$@"
  )
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

  local invoker=run_xcodebuild_command
  if (( use_tuist == 1 )); then
    invoker=run_tuist_xcodebuild_command
  fi

  if command -v xcbeautify >/dev/null 2>&1; then
    local -a xcb_args=(--renderer terminal --is-ci --disable-logging)
    if [[ -n "$junit_path" ]]; then
      /bin/mkdir -p "$(dirname "$junit_path")"
      xcb_args+=(--report junit --report-path "$junit_path")
    fi
    set -o pipefail
    "$invoker" "$@" 2>&1 | xcbeautify "${xcb_args[@]}"
    local status="${PIPESTATUS[0]}"
    set +o pipefail
    return "$status"
  fi
  "$invoker" "$@"
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
