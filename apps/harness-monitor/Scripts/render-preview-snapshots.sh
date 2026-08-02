#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  mise run monitor:preview -- --list
  mise run monitor:preview -- <suite> [output-directory]

Suites:
  dashboard-diff-lab
  task-board-lane-alignment
  task-board-inspector
  task-board-review-report
  task-board-workflow-progress
  task-board-filters
  secret-migration-consent
EOF
}

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' \
    dashboard-diff-lab \
    task-board-lane-alignment \
    task-board-inspector \
    task-board-review-report \
    task-board-workflow-progress \
    task-board-filters \
    secret-migration-consent
  exit 0
fi

suite="${1:-}"
if [[ -z "$suite" ]]; then
  usage >&2
  exit 2
fi

case "$suite" in
  dashboard-diff-lab|task-board-lane-alignment|task-board-inspector|task-board-review-report|task-board-workflow-progress|task-board-filters|secret-migration-consent) ;;
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
suite_label="${suite//-/ }"

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
  task-board-lane-alignment)
    HARNESS_TASK_BOARD_LANE_ALIGNMENT_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
  task-board-inspector)
    HARNESS_TASK_BOARD_INSPECTOR_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
  task-board-review-report)
    HARNESS_TASK_BOARD_REVIEW_REPORT_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
  task-board-workflow-progress)
    HARNESS_TASK_BOARD_WORKFLOW_PROGRESS_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
  task-board-filters)
    HARNESS_TASK_BOARD_FILTERS_PREVIEW_DUMP="$staging_directory" "$host"
    ;;
  secret-migration-consent)
    HARNESS_SECRET_MIGRATION_CONSENT_DUMP="$staging_directory" "$host"
    ;;
esac

mkdir -p "$output_directory"
rendered_count=0
rendered_names=()
rendered_widths=()
rendered_heights=()
rendered_scales=()
while IFS= read -r snapshot; do
  snapshot_name="$(basename "$snapshot")"
  destination_path="$output_directory/$snapshot_name"
  cp -f -- "$snapshot" "$destination_path"
  pixel_width="$(sips -g pixelWidth "$destination_path" | awk '/pixelWidth/ { print $2 }')"
  pixel_height="$(sips -g pixelHeight "$destination_path" | awk '/pixelHeight/ { print $2 }')"
  dpi_width="$(sips -g dpiWidth "$destination_path" | awk '/dpiWidth/ { print $2 }')"
  dpi_height="$(sips -g dpiHeight "$destination_path" | awk '/dpiHeight/ { print $2 }')"
  point_width="$(awk -v pixels="$pixel_width" -v dpi="$dpi_width" \
    'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
  point_height="$(awk -v pixels="$pixel_height" -v dpi="$dpi_height" \
    'BEGIN { printf "%.0f", pixels * 72 / dpi }')"
  render_scale="$(awk -v dpi="$dpi_width" 'BEGIN { printf "%.0f", dpi / 72 }')"
  printf '%s\n' "$destination_path"
  rendered_names+=("$snapshot_name")
  rendered_widths+=("$point_width")
  rendered_heights+=("$point_height")
  rendered_scales+=("$render_scale")
  rendered_count=$((rendered_count + 1))
done < <(find "$staging_directory" -type f -name '*.png' -size +0c -print | LC_ALL=C sort)

if (( rendered_count == 0 )); then
  printf 'error: preview suite produced no non-empty PNG snapshots: %s\n' "$suite" >&2
  exit 1
fi

gallery_path="$output_directory/index.html"
{
  printf '%s\n' \
    '<!doctype html>' \
    '<html lang="en">' \
    '<head>' \
    '  <meta charset="utf-8">' \
    '  <meta name="viewport" content="width=device-width, initial-scale=1">' \
    "  <title>Harness Monitor · $suite</title>" \
    '  <style>' \
    '    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }' \
    '    body { margin: 0; padding: 32px; background: #151515; color: #f5f5f5; }' \
    '    header { display: flex; align-items: end; justify-content: space-between; gap: 20px; margin: 0 0 24px; }' \
    '    h1 { margin: 0 0 8px; font-size: 24px; text-transform: capitalize; }' \
    '    p { margin: 0; color: #aaa; }' \
    '    .layout-controls { display: flex; gap: 4px; padding: 4px; background: #202020; border: 1px solid #353535; border-radius: 10px; }' \
    '    button { padding: 7px 12px; color: #bbb; background: transparent; border: 0; border-radius: 7px; font: inherit; cursor: pointer; }' \
    '    button:hover { color: #fff; background: #2b2b2b; }' \
    '    button[aria-pressed="true"] { color: #fff; background: #3b6fc4; }' \
    '    main { display: grid; gap: 20px; }' \
    '    main[data-columns="two"] { grid-template-columns: repeat(2, minmax(0, 1fr)); }' \
    '    main[data-columns="one"] { grid-template-columns: minmax(0, 1fr); }' \
    '    figure { margin: 0; padding: 16px; overflow: auto; background: #202020; border: 1px solid #353535; border-radius: 12px; }' \
    '    figcaption { display: flex; justify-content: space-between; gap: 16px; margin-bottom: 12px; font-size: 14px; font-weight: 600; }' \
    '    .name { text-transform: capitalize; }' \
    '    .dimensions { color: #888; font-weight: 400; white-space: nowrap; }' \
    '    img { display: block; max-width: 100%; height: auto; margin-inline: auto; border-radius: 8px; background: #1d1d1d; }' \
    '    a { color: inherit; }' \
    '    @media (max-width: 1120px) { main[data-columns="two"] { grid-template-columns: minmax(0, 1fr); } }' \
    '    @media (max-width: 700px) { body { padding: 20px; } header { align-items: stretch; flex-direction: column; } .layout-controls { align-self: start; } }' \
    '  </style>' \
    '</head>' \
    '<body>' \
    '  <header>' \
    '    <div>' \
    "      <h1>$suite_label</h1>" \
    "      <p>$rendered_count snapshots · Click any preview to open the original PNG</p>" \
    '    </div>' \
    '    <div class="layout-controls" role="group" aria-label="Preview columns">' \
    '      <button type="button" data-column-choice="two" aria-pressed="true">Two columns</button>' \
    '      <button type="button" data-column-choice="one" aria-pressed="false">One column</button>' \
    '    </div>' \
    '  </header>' \
    '  <main data-columns="two">'
  for index in "${!rendered_names[@]}"; do
    snapshot_name="${rendered_names[$index]}"
    point_width="${rendered_widths[$index]}"
    point_height="${rendered_heights[$index]}"
    render_scale="${rendered_scales[$index]}"
    snapshot_label="${snapshot_name%.png}"
    snapshot_label="${snapshot_label//-/ }"
    printf '%s\n' \
      '    <figure>' \
      "      <figcaption><span class=\"name\">$snapshot_label</span><span class=\"dimensions\">${point_width} × ${point_height} pt · ${render_scale}×</span></figcaption>" \
      "      <a href=\"$snapshot_name\"><img src=\"$snapshot_name\" alt=\"$snapshot_label\" width=\"$point_width\" height=\"$point_height\"></a>" \
      '    </figure>'
  done
  printf '%s\n' \
    '  </main>' \
    '  <script>' \
    '    const grid = document.querySelector("main");' \
    '    const columnButtons = document.querySelectorAll("[data-column-choice]");' \
    '    for (const button of columnButtons) {' \
    '      button.addEventListener("click", () => {' \
    '        grid.dataset.columns = button.dataset.columnChoice;' \
    '        for (const candidate of columnButtons) {' \
    '          candidate.setAttribute("aria-pressed", String(candidate === button));' \
    '        }' \
    '      });' \
    '    }' \
    '  </script>' \
    '</body>' \
    '</html>'
} > "$gallery_path"
printf '%s\n' "$gallery_path"
