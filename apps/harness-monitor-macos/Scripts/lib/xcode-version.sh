#!/bin/bash

print_harness_monitor_dtxcode_from_plist() {
  local plist_path="$1"
  local dtxcode

  if [ ! -f "$plist_path" ]; then
    return 1
  fi

  dtxcode="$(/usr/libexec/PlistBuddy -c "Print :DTXcode" "$plist_path" 2>/dev/null || true)"
  if [[ "$dtxcode" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$dtxcode"
    return 0
  fi

  return 1
}

harness_monitor_xcode_info_plist_for_developer_dir() {
  local developer_dir="$1"

  if [[ "$developer_dir" == */Contents/Developer ]]; then
    printf '%s/Contents/Info.plist\n' "${developer_dir%/Contents/Developer}"
  fi
}

harness_monitor_current_xcode_dtxcode() {
  local override="${HARNESS_MONITOR_XCODE_DTXCODE:-}"
  local developer_dir
  local info_plist
  local selected_developer_dir

  if [ -n "$override" ]; then
    if [[ "$override" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$override"
      return 0
    fi
    return 1
  fi

  developer_dir="${DEVELOPER_DIR:-}"
  if [ -n "$developer_dir" ]; then
    info_plist="$(harness_monitor_xcode_info_plist_for_developer_dir "$developer_dir")"
    if print_harness_monitor_dtxcode_from_plist "$info_plist"; then
      return 0
    fi
  fi

  selected_developer_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ -n "$selected_developer_dir" ]; then
    info_plist="$(harness_monitor_xcode_info_plist_for_developer_dir "$selected_developer_dir")"
    if print_harness_monitor_dtxcode_from_plist "$info_plist"; then
      return 0
    fi
  fi

  print_harness_monitor_dtxcode_from_plist "/Applications/Xcode.app/Contents/Info.plist"
}

harness_monitor_default_xcode_upgrade_check() {
  harness_monitor_current_xcode_dtxcode || printf '2640\n'
}
