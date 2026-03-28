#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DESTINATION="${XCODEBUILD_DESTINATION:-platform=macOS}"

"$ROOT/Scripts/generate-project.sh"
"$ROOT/Scripts/lint-swift.sh" all
xcodebuild -project "$ROOT/HarnessMonitor.xcodeproj" -scheme HarnessMonitor -destination "$DESTINATION" test
