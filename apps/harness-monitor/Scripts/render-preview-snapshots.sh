#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  mise run monitor:preview -- --list
  mise run monitor:preview -- <suite> [output-directory]

Suites:
  dashboard-diff-lab
  task-board-inspector
EOF
}

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' dashboard-diff-lab task-board-inspector
  exit 0
fi

suite="${1:-}"
if [[ -z "$suite" ]]; then
  usage >&2
  exit 2
fi

case "$suite" in
  dashboard-diff-lab|task-board-inspector) ;;
  *)
    printf 'error: unknown preview suite: %s\n' "$suite" >&2
    usage >&2
    exit 2
    ;;
esac

script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
app_root="$(CDPATH='' cd -- "$script_dir/.." && pwd)"
checkout_root="$(CDPATH='' cd -- "$app_root/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$checkout_root/scripts/lib/common-repo-root.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$script_dir/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcodebuild-destination.sh
source "$script_dir/lib/xcodebuild-destination.sh"

common_repo_root="$(resolve_common_repo_root "$checkout_root")"
derived_data="$(harness_monitor_build_derived_data_path "$common_repo_root")"
destination="$(harness_monitor_xcodebuild_destination)"
output_directory="${2:-$checkout_root/tmp/preview-snapshots/$suite}"
if [[ "$output_directory" != /* ]]; then
  output_directory="$checkout_root/$output_directory"
fi

"$script_dir/monitor-xcodebuild.sh" \
  -workspace "$app_root/HarnessMonitor.xcworkspace" \
  -scheme HarnessMonitorUIPreviews \
  -configuration Preview \
  -destination "$destination" \
  -skipPackagePluginValidation \
  build

host="$derived_data/Build/Products/Preview/HarnessMonitorPreviewHost.app/Contents/MacOS/HarnessMonitorPreviewHost"
if [[ ! -x "$host" ]]; then
  printf 'error: preview host missing after build: %s\n' "$host" >&2
  exit 1
fi

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/harness-monitor-preview.XXXXXX")"
cleanup() {
  rm -rf -- "$staging_directory"
}
trap cleanup EXIT

case "$suite" in
  dashboard-diff-lab)
    HARNESS_DIFF_LAB_DUMP="$staging_directory" "$host"
    ;;
  task-board-inspector)
    HARNESS_TASK_BOARD_INSPECTOR_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
esac

mkdir -p "$output_directory"
rendered_count=0
while IFS= read -r -d '' snapshot; do
  destination_path="$output_directory/$(basename "$snapshot")"
  cp -f -- "$snapshot" "$destination_path"
  printf '%s\n' "$destination_path"
  rendered_count=$((rendered_count + 1))
done < <(find "$staging_directory" -type f -name '*.png' -size +0 -print0)

if (( rendered_count == 0 )); then
  printf 'error: preview suite produced no non-empty PNG snapshots: %s\n' "$suite" >&2
  exit 1
fi
