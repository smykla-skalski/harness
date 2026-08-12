#!/bin/bash

harness_monitor_test_code_signing_allowed() {
  local test_scheme="$1"
  local only_testing="${2:-}"

  if [[ -n "${HARNESS_MONITOR_CODE_SIGNING_ALLOWED:-}" ]]; then
    printf '%s\n' "$HARNESS_MONITOR_CODE_SIGNING_ALLOWED"
    return 0
  fi

  case "$test_scheme" in
    HarnessMonitor|HarnessMonitorAppTests|HarnessMonitorUITestHost)
      # These schemes load tests inside an app that uses the shared app-group
      # container. An ad-hoc host has no team entitlement, so macOS prompts for
      # access to data from other apps every time Xcode creates a new host.
      printf 'YES\n'
      return 0
      ;;
  esac

  case "$only_testing" in
    *HarnessMonitorUITests*|*HarnessMonitorAgentsE2ETests*)
      printf 'YES\n'
      ;;
    *)
      printf 'NO\n'
      ;;
  esac
}
