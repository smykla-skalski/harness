#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CHECKOUT_ROOT="$(CDPATH='' cd -- "$ROOT/../.." && pwd)"
# shellcheck source=scripts/lib/common-repo-root.sh
source "$CHECKOUT_ROOT/scripts/lib/common-repo-root.sh"
COMMON_REPO_ROOT="$(resolve_common_repo_root "$CHECKOUT_ROOT")"
# shellcheck source=apps/harness-monitor/Scripts/lib/monitor-lanes.sh
source "$ROOT/Scripts/lib/monitor-lanes.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/build-for-testing-reuse.sh
source "$ROOT/Scripts/lib/build-for-testing-reuse.sh"

DERIVED_DATA_PATH="$(harness_monitor_build_derived_data_path "$COMMON_REPO_ROOT")"
TEST_SCHEME="${HARNESS_MONITOR_TEST_SCHEME:-HarnessMonitorPolicyCanvasAlgorithmTests}"
export HARNESS_MONITOR_TEST_SCHEME="$TEST_SCHEME"
export HARNESS_MONITOR_TEST_XCTESTRUN_PREFIX="${HARNESS_MONITOR_TEST_XCTESTRUN_PREFIX:-$TEST_SCHEME}"

if [[ -n "${XCODE_ONLY_TESTING:-}" ]]; then
  exec "$ROOT/Scripts/test-swift.sh"
fi

if ! should_reuse_existing_build_for_testing; then
  exec "$ROOT/Scripts/test-swift.sh"
fi

XCTESTRUN_PATH="$(existing_xctestrun_path)"
if [[ -z "$XCTESTRUN_PATH" ]]; then
  exec "$ROOT/Scripts/test-swift.sh"
fi

eval "$(
  python3 - "$XCTESTRUN_PATH" "$TEST_SCHEME" <<'PY'
import os
import plistlib
import shlex
import sys

xctestrun_path = sys.argv[1]
scheme = sys.argv[2]
with open(xctestrun_path, "rb") as handle:
    data = plistlib.load(handle)

entry = data[scheme]
test_root = os.path.dirname(xctestrun_path)
xcode_developer = "/Applications/Xcode.app/Contents/Developer"
replacements = {
    "__TESTROOT__": test_root,
    "__PLATFORMS__": f"{xcode_developer}/Platforms",
    "__DEVELOPERUSRLIB__": f"{xcode_developer}/usr/lib",
    "__SHAREDFRAMEWORKS__": "/Applications/Xcode.app/Contents/SharedFrameworks",
}

def expand(value: str) -> str:
    result = value
    for key, replacement in replacements.items():
        result = result.replace(key, replacement)
    return result

print(f"TEST_BUNDLE_PATH={shlex.quote(expand(entry['TestBundlePath']))}")
print(f"TEST_HOST_PATH={shlex.quote(expand(entry['TestHostPath']))}")

env = {}
env.update(entry.get("EnvironmentVariables", {}))
env.update(entry.get("TestingEnvironmentVariables", {}))
for key, value in sorted(env.items()):
    if isinstance(value, str):
        print(f"export {key}={shlex.quote(expand(value))}")
PY
)"

exec "$TEST_HOST_PATH" "$TEST_BUNDLE_PATH"
