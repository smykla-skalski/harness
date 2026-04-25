#!/bin/bash
set -eu

# Writes HarnessMonitorBuildProvenance.plist into the bundle resources and
# strips Gatekeeper xattrs from the built product. Wired as a Run Script
# build phase by Tuist for both the HarnessMonitor and HarnessMonitorUITestHost
# targets; pass "monitor-app" or "ui-test-host" as $1.

VARIANT="${1:?variant arg required: monitor-app or ui-test-host}"

if [ "${XCODE_RUNNING_FOR_PREVIEWS:-}" = "1" ] || [[ "${BUILD_DIR:-}" == *"/Previews/"* ]]; then
  exit 0
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"

resolve_repo_root() {
  local candidate="$PROJECT_DIR"
  while [ "$candidate" != "/" ]; do
    if [ -d "$candidate/.git" ] || [ -f "$candidate/.git" ]; then
      printf '%s\n' "$candidate"
      return
    fi
    candidate="$(dirname "$candidate")"
  done
  printf '%s\n' "$PROJECT_DIR"
}

repo_root="$(resolve_repo_root)"
build_commit="${HARNESS_MONITOR_BUILD_GIT_COMMIT:-}"
if [ -z "$build_commit" ]; then
  build_commit="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
fi

build_dirty="${HARNESS_MONITOR_BUILD_GIT_DIRTY:-}"
if [ -z "$build_dirty" ]; then
  if [ -n "$(git -C "$repo_root" status --short 2>/dev/null || true)" ]; then
    build_dirty="true"
  else
    build_dirty="false"
  fi
fi

build_workspace_fingerprint="${HARNESS_MONITOR_BUILD_WORKSPACE_FINGERPRINT:-}"
if [ -z "$build_workspace_fingerprint" ]; then
  if [ "${ENABLE_USER_SCRIPT_SANDBOXING:-}" = "YES" ]; then
    build_workspace_fingerprint="unavailable-user-script-sandbox"
  else
    build_workspace_fingerprint="$(/usr/bin/python3 "$SCRIPT_DIR/workspace-tree-fingerprint.py" "$VARIANT" "$PROJECT_DIR")"
  fi
fi

build_started_at_utc="${HARNESS_MONITOR_BUILD_STARTED_AT_UTC:-}"
if [ -z "$build_started_at_utc" ]; then
  build_started_at_utc="$(TZ=UTC /bin/date +%Y-%m-%dT%H:%M:%SZ)"
fi

provenance_path="${SCRIPT_OUTPUT_FILE_0:-$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/HarnessMonitorBuildProvenance.plist}"
resources_dir="$(dirname "$provenance_path")"

/bin/mkdir -p "$resources_dir"
/bin/cat > "$provenance_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>HarnessMonitorBuildGitCommit</key>
  <string>${build_commit}</string>
  <key>HarnessMonitorBuildGitDirty</key>
  <string>${build_dirty}</string>
  <key>HarnessMonitorBuildWorkspaceFingerprint</key>
  <string>${build_workspace_fingerprint}</string>
  <key>HarnessMonitorBuildStartedAtUTC</key>
  <string>${build_started_at_utc}</string>
</dict>
</plist>
EOF

target_path="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
if [ -e "$target_path" ]; then
  /usr/bin/xattr -dr com.apple.provenance "$target_path" 2>/dev/null || true
  /usr/bin/xattr -dr com.apple.quarantine "$target_path" 2>/dev/null || true
fi
