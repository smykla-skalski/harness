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

  {
    printf 'error: %s failed\n' "$label"
    printf '  command: %s\n' "$(harness_format_command "$@")"
    printf '  reason: %s\n' "$(harness_status_summary "$status")"
  } >&2
  return "$status"
}
