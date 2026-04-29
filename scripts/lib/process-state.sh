#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'error: process-state.sh must be sourced, not executed directly\n' >&2
  exit 1
fi

process_state_trim_ps_field() {
  sed 's/^[[:space:]]*//; s/[[:space:]]\+/ /g; s/[[:space:]]$//'
}

process_state_hostname() {
  /bin/hostname
}

process_state_command_string() {
  local target_pid="${1:-}"
  local command_string

  [[ "$target_pid" =~ ^[0-9]+$ ]] || return 1
  command_string="$(ps -p "$target_pid" -o command= 2>/dev/null | process_state_trim_ps_field || true)"
  [[ -n "$command_string" ]] || return 1
  printf '%s\n' "$command_string"
}

process_state_start_string() {
  local target_pid="${1:-}"
  local start_string

  [[ "$target_pid" =~ ^[0-9]+$ ]] || return 1
  start_string="$(ps -p "$target_pid" -o lstart= 2>/dev/null | process_state_trim_ps_field || true)"
  [[ -n "$start_string" ]] || return 1
  printf '%s\n' "$start_string"
}

process_state_identity_matches() {
  local target_pid="$1"
  local expected_start="${2:-}"
  local expected_command="${3:-}"
  local current_start current_command

  [[ "$target_pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$target_pid" 2>/dev/null || return 1

  if [[ -n "$expected_start" ]]; then
    current_start="$(process_state_start_string "$target_pid" || true)"
    [[ -n "$current_start" && "$current_start" == "$expected_start" ]] || return 1
  fi

  if [[ -n "$expected_command" ]]; then
    current_command="$(process_state_command_string "$target_pid" || true)"
    [[ -n "$current_command" && "$current_command" == "$expected_command" ]] || return 1
  fi

  return 0
}
