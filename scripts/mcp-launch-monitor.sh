#!/usr/bin/env bash
# Open the Debug build of Harness Monitor.app produced by the xcodebuild
# lane used by `mise run mcp:build:monitor`. Fails loud if the build
# output is missing.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$ROOT")"
app_path="$COMMON_REPO_ROOT/xcode-derived/Build/Products/Debug/Harness Monitor.app"
if [[ ! -d "$app_path" ]]; then
  printf "error: %s not found. Run \`mise run mcp:build:monitor\` first.\n" "$app_path" >&2
  exit 1
fi
open "$app_path"
