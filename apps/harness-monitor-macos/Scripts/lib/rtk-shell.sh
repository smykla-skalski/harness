#!/bin/bash

run_xcodebuild_command() {
  xcodebuild "$@"
}

print_log_tail_compact() {
  local lines="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  /usr/bin/tail -n "$lines" "$path"
}
