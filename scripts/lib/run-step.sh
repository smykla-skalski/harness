#!/usr/bin/env bash
# Shared failure-reporting helpers for repo-local shell entrypoints.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: run-step.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

harness_format_command() {
  local formatted="" arg quoted
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    if [[ -n "$formatted" ]]; then
      formatted+=" "
    fi
    formatted+="$quoted"
  done
  printf '%s\n' "$formatted"
}

harness_status_summary() {
  local status="$1"
  if (( status == 126 )); then
    printf 'exit status 126 (command found but not executable)\n'
    return 0
  fi
  if (( status == 127 )); then
    printf 'exit status 127 (command not found)\n'
    return 0
  fi
  if (( status > 128 )); then
    local signal=$((status - 128))
    local signal_name
    signal_name="$(kill -l "$signal" 2>/dev/null || true)"
    if [[ -n "$signal_name" ]]; then
      printf 'terminated by signal %s (%s), shell status %s\n' "$signal_name" "$signal" "$status"
    else
      printf 'terminated by signal %s, shell status %s\n' "$signal" "$status"
    fi
    return 0
  fi
  printf 'exit status %s\n' "$status"
}

harness_status_is_accepted() {
  local status="$1" accepted raw
  # Interactive foreground tasks can opt into treating specific signal-shaped
  # exits as expected teardown so wrapper noise does not turn Ctrl+C into a
  # scary task failure. Keep this opt-in at the task boundary.
  raw="${HARNESS_RUN_STEP_ACCEPT_STATUSES:-}"
  [[ -n "$raw" ]] || return 1

  raw="${raw//,/ }"
  for accepted in $raw; do
    if [[ "$accepted" =~ ^[0-9]+$ ]] && (( status == accepted )); then
      return 0
    fi
  done
  return 1
}

harness_run_step() {
  local label="$1"
  shift

  if (( $# == 0 )); then
    {
      printf 'error: %s failed\n' "$label"
      printf '  command: <empty>\n'
      printf '  reason: no command specified\n'
    } >&2
    return 2
  fi

  local had_errexit=0
  case $- in
    *e*) had_errexit=1 ;;
  esac

  set +e
  "$@"
  local status=$?
  if (( had_errexit )); then
    set -e
  fi

  if (( status == 0 )); then
    return 0
  fi
  if harness_status_is_accepted "$status"; then
    return 0
  fi

  {
    printf 'error: %s failed\n' "$label"
    printf '  command: %s\n' "$(harness_format_command "$@")"
    printf '  reason: %s\n' "$(harness_status_summary "$status")"
  } >&2
  return "$status"
}
