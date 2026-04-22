#!/bin/bash

find_rtk_bin() {
  if [[ -n "${RTK_BIN:-}" && -x "${RTK_BIN}" ]]; then
    printf '%s\n' "${RTK_BIN}"
    return 0
  fi

  if command -v rtk >/dev/null 2>&1; then
    command -v rtk
    return 0
  fi

  return 1
}

rtk_disabled_for_script() {
  case "${RTK_DISABLED:-}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

xcodebuild_supports_rtk_filtering() {
  local arg

  if rtk_disabled_for_script || ! find_rtk_bin >/dev/null 2>&1; then
    return 1
  fi

  for arg in "$@"; do
    case "$arg" in
      -json|-showBuildSettings)
        return 1
        ;;
    esac
  done

  return 0
}

run_xcodebuild_command() {
  local rtk_bin

  if xcodebuild_supports_rtk_filtering "$@"; then
    rtk_bin="$(find_rtk_bin)"
    "$rtk_bin" xcodebuild "$@"
    return
  fi

  xcodebuild "$@"
}

print_log_tail_compact() {
  local lines="$1"
  local path="$2"
  local rtk_bin

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  if rtk_bin="$(find_rtk_bin 2>/dev/null)" && [[ -n "$rtk_bin" ]]; then
    if "$rtk_bin" read "$path" --tail-lines "$lines"; then
      return 0
    fi
  fi

  /usr/bin/tail -n "$lines" "$path"
}
