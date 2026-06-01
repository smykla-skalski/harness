#!/usr/bin/env bash
set -uo pipefail

# Build the lane-isolated Harness Monitor app, launch its Policy Canvas Lab
# window (optionally rendering a specific policy document), and screenshot it.
#
# Why the isolated target: HarnessMonitorIsolated self-signs with automatic
# Apple Development signing, carries a lane-scoped bundle id so LaunchServices
# never hands the launch to the developer's running io.harnessmonitor.app, and
# ships minimal entitlements (no iCloud / app group) so there is no CloudKit
# container to trap. That removes the manual re-sign, provisioning-profile copy,
# and shared-sandbox-container workarounds the production target needs.
#
# Inputs (env, all optional):
#   HARNESS_MONITOR_BUILD_LANE          DerivedData + isolated bundle id lane
#   HARNESS_MONITOR_POLICY_LAB_FIXTURE  pipeline-document JSON to render in the lab
#   HARNESS_MONITOR_POLICY_LAB_OUT      output PNG (default tmp/policy-canvas-lab/<lane>.png)
#   HARNESS_MONITOR_POLICY_LAB_GENERATE 1 = regenerate the Xcode project first

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$APP_ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$SCRIPT_DIR/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcodebuild-destination.sh
source "$SCRIPT_DIR/lib/xcodebuild-destination.sh"

COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
LANE="$(harness_monitor_build_lane)"
# Pin runtime state to this lane instead of the shared default root. The lab
# launch itself uses preview mode and does not bootstrap the daemon; the lane is
# still exported so any explicitly requested fixture/runtime path stays isolated.
export HARNESS_MONITOR_RUNTIME_LANE="${HARNESS_MONITOR_RUNTIME_LANE:-$LANE}"
DERIVED="$(harness_monitor_build_derived_data_path "$COMMON_REPO_ROOT")"
DESTINATION="$(harness_monitor_xcodebuild_destination)"
APP="$DERIVED/Build/Products/Debug/Harness Monitor Isolated.app"
BINARY="$APP/Contents/MacOS/Harness Monitor Isolated"
OUT="${HARNESS_MONITOR_POLICY_LAB_OUT:-$CHECKOUT_ROOT/tmp/policy-canvas-lab/$LANE.png}"
FIXTURE="${HARNESS_MONITOR_POLICY_LAB_FIXTURE:-}"
WORK_DIR="$(dirname "$OUT")"
mkdir -p "$WORK_DIR"
BUILD_LOG="$WORK_DIR/build-$LANE.log"
FINDER="$WORK_DIR/.find-window.swift"

# 1. Generate (only when forced) so the isolated bundle id is baked for this lane.
if [[ "${HARNESS_MONITOR_POLICY_LAB_GENERATE:-0}" == "1" ]]; then
  echo "generating Xcode project for lane $LANE"
  "$SCRIPT_DIR/generate.sh" > "$WORK_DIR/generate-$LANE.log" 2>&1 \
    || { echo "generate failed; see $WORK_DIR/generate-$LANE.log" >&2; tail -20 "$WORK_DIR/generate-$LANE.log" >&2; exit 1; }
fi

# 2. Build the isolated scheme. Do NOT pass CODE_SIGNING_ALLOWED=NO: the target
#    self-signs via automatic Apple Development signing.
echo "building HarnessMonitorIsolated (lane $LANE) -> $BUILD_LOG"
"$SCRIPT_DIR/monitor-xcodebuild.sh" \
  -workspace "$APP_ROOT/HarnessMonitor.xcworkspace" \
  -scheme HarnessMonitorIsolated \
  -configuration Debug \
  -destination "$DESTINATION" \
  -skipPackagePluginValidation \
  build DEVELOPMENT_TEAM=Q498EB36N4 > "$BUILD_LOG" 2>&1
if grep -qiE "error:|BUILD FAILED|requires a provisioning|requires a development team" "$BUILD_LOG"; then
  echo "BUILD FAILED:" >&2; grep -iE "error:|BUILD FAILED|requires a (provisioning|development)" "$BUILD_LOG" | head >&2; exit 1
fi
if [[ ! -x "$BINARY" ]]; then
  echo "error: isolated app binary missing after build: $BINARY" >&2; exit 1
fi

# Read the actually-baked bundle id; its sandbox container is where the app
# writes the fixture decode log.
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)"
CONTAINER="$HOME/Library/Containers/$ACTUAL_BUNDLE_ID/Data"
DECODE_LOG="$CONTAINER/policy-canvas-lab-decode.log"
echo "isolated bundle id: $ACTUAL_BUNDLE_ID"

# The isolated app has no app-group access, so its MCP registry host can never
# open the shared capability token and would raise a "registry degraded" toast
# over the canvas. The lab does not need MCP, so disable the host for lab runs.
if [[ -n "$ACTUAL_BUNDLE_ID" ]]; then
  mkdir -p "$CONTAINER/Library/Preferences" 2>/dev/null
  defaults write "$CONTAINER/Library/Preferences/$ACTUAL_BUNDLE_ID" \
    harnessMonitorMCPRegistryHostEnabled -bool false 2>/dev/null || true
fi

# 3. Fixture -> base64 env (survives the sandbox with no file-read permission).
fixture_env=()
if [[ -n "$FIXTURE" ]]; then
  [[ -f "$FIXTURE" ]] || { echo "error: fixture not found: $FIXTURE" >&2; exit 1; }
  echo "rendering fixture: $FIXTURE"
  b64="$(base64 < "$FIXTURE" | tr -d '\n')"
  fixture_env=(--env "HARNESS_MONITOR_POLICY_CANVAS_LAB_FIXTURE_B64=$b64")
  rm -f "$DECODE_LOG" 2>/dev/null
fi

# 4. Relaunch: close any app already running from this lane's build products
#    (the prior lab window, isolated or production target), then force a fresh
#    instance so the env (and fixture) applies. Scoped to the lane dir, so the
#    developer's own io.harnessmonitor.app is never touched.
LANE_PRODUCTS="$DERIVED/Build/Products/Debug"
for _ in $(seq 1 12); do
  pgrep -f "$LANE_PRODUCTS/Harness Monitor" >/dev/null || break
  pkill -f "$LANE_PRODUCTS/Harness Monitor" 2>/dev/null
  sleep 1
done
# `-g` keeps the launch in the background: the lab renders and is screenshot by
# window id (works across Spaces) without stealing the developer's focus.
open -g -n "$APP" \
  --env "HARNESS_MONITOR_LAUNCH_MODE=preview" \
  --env "HARNESS_MONITOR_POLICY_CANVAS_LAB=1" \
  --env "HARNESS_MONITOR_RUNTIME_LANE=$LANE" \
  --env "HARNESS_MONITOR_DISABLE_MOBILE_RELAY=1" \
  ${fixture_env[@]+"${fixture_env[@]}"} \
  || { echo "error: open failed" >&2; exit 1; }

# 5. Window finder (CGWindowList), emitted as: windowID \t area \t title. Uses
#    optionAll so the lab window is found even when it opened on another Space;
#    screencapture -l captures a window by id regardless of which Space it is on.
cat > "$FINDER" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil
let needle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
guard let list = CGWindowListCopyWindowInfo(
  [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
else { exit(1) }
for window in list {
  let owner = window[kCGWindowOwnerPID as String] as? Int ?? -1
  if let pid, owner != pid { continue }
  let name = window[kCGWindowName as String] as? String ?? ""
  if !needle.isEmpty && !name.contains(needle) { continue }
  let number = window[kCGWindowNumber as String] as? Int ?? -1
  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
  let area = Int((bounds["Width"] ?? 0) * (bounds["Height"] ?? 0))
  print("\(number)\t\(area)\t\(name)")
}
SWIFT

resolve_lab_window() {
  local pid="$1"
  swift "$FINDER" "$pid" "Policy Canvas Lab" 2>/dev/null \
    | sort -t$'\t' -k2 -rn | head -1 | cut -f1
}

# 6. Wait for the lab window to appear.
pid=""; winid=""
for _ in $(seq 1 40); do
  pid="$(pgrep -f "$BINARY" | head -1)"
  [[ -z "$pid" ]] && { sleep 1; continue; }
  winid="$(resolve_lab_window "$pid")"
  area="$(swift "$FINDER" "$pid" "Policy Canvas Lab" 2>/dev/null | sort -t$'\t' -k2 -rn | head -1 | cut -f2)"
  [[ -n "$area" && "$area" -gt 150000 ]] && break
  winid=""; sleep 1
done

printf '=== fixture decode log (%s) ===\n' "$DECODE_LOG"
cat "$DECODE_LOG" 2>/dev/null || echo "(none)"

if [[ -z "$winid" ]]; then
  echo "error: no Policy Canvas Lab window for pid=${pid:-?}" >&2
  [[ -n "$pid" ]] && swift "$FINDER" "$pid" 2>/dev/null >&2
  exit 2
fi

# 7. Let the canvas finish its async fetch+layout, then capture by window id.
#    Re-resolve before each attempt so a recreated window never leaves a stale id.
sleep 5
for _ in 1 2 3 4; do
  winid="$(resolve_lab_window "$pid")"
  if [[ -n "$winid" ]] && screencapture -l "$winid" -o "$OUT" 2>/dev/null && [[ -s "$OUT" ]]; then
    printf 'captured %s (%s bytes)\n' "$OUT" "$(wc -c < "$OUT" | tr -d ' ')"
    exit 0
  fi
  sleep 1
done
echo "error: screencapture failed for winid=${winid:-?}" >&2
exit 3
