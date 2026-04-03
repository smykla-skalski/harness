#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
REPO_ROOT="$SCRIPT_DIR/../../.."
MEASUREMENTS_DIR="$REPO_ROOT/tmp/investigations/xcode-preview-speed/measurements"
DERIVED_DATA="$ROOT/tmp/xcode-derived"

label="${1:-unnamed}"
rounds="${2:-3}"

project="$ROOT/HarnessMonitor.xcodeproj"
scheme="HarnessMonitorUIPreviews"
configuration="Preview"
destination="platform=macOS"

if [ ! -d "$project" ]; then
  echo "Project not found at $project" >&2
  echo "Run Scripts/generate-project.sh first." >&2
  exit 1
fi

mkdir -p "$MEASUREMENTS_DIR"

timestamp="$(date +%Y%m%d-%H%M%S)"
output_file="$MEASUREMENTS_DIR/${timestamp}-${label}.json"

xcodebuild_cmd=(
  xcodebuild
  -project "$project"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "$destination"
  -derivedDataPath "$DERIVED_DATA"
  -skipPackagePluginValidation
  build
)

measure_clean() {
  rm -rf "$DERIVED_DATA"
  local start end elapsed
  start="$(python3 -c 'import time; print(int(time.time()*1000))')"
  "${xcodebuild_cmd[@]}" >/dev/null 2>&1
  end="$(python3 -c 'import time; print(int(time.time()*1000))')"
  elapsed=$(( end - start ))
  echo "$elapsed"
}

measure_incremental() {
  touch "$ROOT/Sources/HarnessMonitorUI/Views/ContentView.swift"
  local start end elapsed
  start="$(python3 -c 'import time; print(int(time.time()*1000))')"
  "${xcodebuild_cmd[@]}" >/dev/null 2>&1
  end="$(python3 -c 'import time; print(int(time.time()*1000))')"
  elapsed=$(( end - start ))
  echo "$elapsed"
}

echo "Measuring preview build times: label=$label, rounds=$rounds"
echo "Project: $project"
echo "Scheme: $scheme ($configuration)"
echo ""

clean_times=()
incremental_times=()

for i in $(seq 1 "$rounds"); do
  echo "--- Round $i/$rounds ---"

  echo -n "  Clean build... "
  ct="$(measure_clean)"
  clean_times+=("$ct")
  echo "${ct}ms"

  echo -n "  Incremental build... "
  it="$(measure_incremental)"
  incremental_times+=("$it")
  echo "${it}ms"
done

python3 - "$output_file" "$label" "$rounds" "${clean_times[@]}" "---" "${incremental_times[@]}" <<'PY'
import json
import statistics
import sys

output_file = sys.argv[1]
label = sys.argv[2]
rounds = int(sys.argv[3])

rest = sys.argv[4:]
sep = rest.index("---")
clean_ms = [int(x) for x in rest[:sep]]
incremental_ms = [int(x) for x in rest[sep + 1:]]

def summarize(values):
    return {
        "samples": values,
        "min_ms": min(values),
        "max_ms": max(values),
        "mean_ms": round(statistics.mean(values)),
        "median_ms": round(statistics.median(values)),
    }

result = {
    "label": label,
    "rounds": rounds,
    "clean_build": summarize(clean_ms),
    "incremental_build": summarize(incremental_ms),
}

with open(output_file, "w") as f:
    json.dump(result, f, indent=2)

print()
print(f"Results written to {output_file}")
print()
print(f"Clean build:       min={min(clean_ms)}ms  mean={round(statistics.mean(clean_ms))}ms  median={round(statistics.median(clean_ms))}ms")
print(f"Incremental build: min={min(incremental_ms)}ms  mean={round(statistics.mean(incremental_ms))}ms  median={round(statistics.median(incremental_ms))}ms")
PY
