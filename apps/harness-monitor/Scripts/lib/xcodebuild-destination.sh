#!/bin/bash

harness_monitor_xcodebuild_default_destination() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    arm64|x86_64)
      printf '%s\n' "platform=macOS,arch=$arch,name=My Mac"
      ;;
    *)
      printf '%s\n' "platform=macOS,name=My Mac"
      ;;
  esac
}

harness_monitor_xcodebuild_destination() {
  local default_destination
  default_destination="$(harness_monitor_xcodebuild_default_destination)"
  printf '%s\n' "${HARNESS_MONITOR_XCODEBUILD_DESTINATION:-${XCODEBUILD_DESTINATION:-$default_destination}}"
}
