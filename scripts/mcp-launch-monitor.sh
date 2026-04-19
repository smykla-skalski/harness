#!/usr/bin/env bash
# Open the Debug build of Harness Monitor.app produced by the xcodebuild
# lane used by `mise run mcp:build:monitor`. Fails loud if the build
# output is missing.
set -euo pipefail

app_path="tmp/xcode-derived/Build/Products/Debug/Harness Monitor.app"
if [[ ! -d "$app_path" ]]; then
  printf 'error: %s not found. Run `mise run mcp:build:monitor` first.\n' "$app_path" >&2
  exit 1
fi
open "$app_path"
