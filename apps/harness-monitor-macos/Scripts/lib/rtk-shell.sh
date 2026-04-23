#!/bin/bash

run_xcodebuild_command() {
  local xcodebuild_bin="${XCODEBUILD_BIN:-/usr/bin/xcodebuild}"
  if [[ ! -x "$xcodebuild_bin" ]]; then
    echo "xcodebuild binary is not executable: $xcodebuild_bin" >&2
    return 127
  fi
  "$xcodebuild_bin" "$@"
}

print_log_tail_compact() {
  local lines="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  /usr/bin/tail -n "$lines" "$path"
}
