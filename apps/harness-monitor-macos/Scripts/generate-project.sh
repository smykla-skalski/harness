#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ROOT="${HARNESS_MONITOR_APP_ROOT:-$ROOT}"
REPO_ROOT="${REPO_ROOT:-$(cd "$ROOT/../.." && pwd)}"
XCODEGEN_BIN="${XCODEGEN_BIN:-$(command -v xcodegen || true)}"
BUILD_SERVER_VERSION="1.3.0"
EXPECTED_XCODEGEN_VERSION="${HARNESS_MONITOR_EXPECTED_XCODEGEN_VERSION:-2.45.4}"
NORMALIZE_ONLY="${HARNESS_MONITOR_NORMALIZE_ONLY:-0}"
SCHEMES_DIR="$ROOT/HarnessMonitor.xcodeproj/xcshareddata/xcschemes"

detect_xcodegen_version() {
  local raw
  raw="$("$XCODEGEN_BIN" --version 2>/dev/null | head -n1 || true)"
  if [[ "$raw" =~ ([0-9]+(\.[0-9]+)+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

enforce_supported_xcodegen_version() {
  local actual_version

  if [ "${HARNESS_MONITOR_ALLOW_UNSUPPORTED_XCODEGEN:-0}" = "1" ]; then
    return
  fi

  actual_version="$(detect_xcodegen_version)"
  if [ -z "$actual_version" ]; then
    echo \
      "could not determine xcodegen version from $XCODEGEN_BIN --version; expected $EXPECTED_XCODEGEN_VERSION" \
      >&2
    exit 1
  fi

  if [ "$actual_version" != "$EXPECTED_XCODEGEN_VERSION" ]; then
    cat >&2 <<EOF
unsupported xcodegen version: $actual_version
expected xcodegen version: $EXPECTED_XCODEGEN_VERSION
refusing to rewrite tracked Harness Monitor project files because mismatched xcodegen versions churn shared scheme XML
set HARNESS_MONITOR_ALLOW_UNSUPPORTED_XCODEGEN=1 only for an intentional generator upgrade
EOF
    exit 1
  fi
}

PBXPROJ="$ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
LOCAL_REGISTRY_PACKAGE_RELATIVE_PATH="../../mcp-servers/harness-monitor-registry"
LOCAL_REGISTRY_PRODUCT_NAME="HarnessMonitorRegistry"

SUPPORTED_FEATURES=("LOTTIE" "OTEL")
MERGED_SPEC="$ROOT/.project.merged.yml"

is_feature_enabled() {
  local feature_name="$1"
  local env_var_name="HARNESS_FEATURE_${feature_name}"
  local raw_value="${!env_var_name:-}"
  case "$(printf '%s' "$raw_value" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

compose_feature_spec() {
  local enabled=()
  local feature_name fragment_name fragment_path
  {
    printf 'include:\n'
    printf '  - path: project.yml\n'
    for feature_name in "${SUPPORTED_FEATURES[@]}"; do
      if is_feature_enabled "$feature_name"; then
        fragment_name="$(printf '%s' "$feature_name" | tr '[:upper:]' '[:lower:]')"
        fragment_path="$ROOT/features/${fragment_name}.yml"
        if [ ! -f "$fragment_path" ]; then
          echo "missing feature fragment: $fragment_path" >&2
          exit 1
        fi
        printf '  - path: features/%s.yml\n' "$fragment_name"
        enabled+=("$feature_name")
      fi
    done
  } > "$MERGED_SPEC"
  if (( ${#enabled[@]} > 0 )); then
    printf 'monitor: feature flags enabled: %s\n' "${enabled[*]}" >&2
  else
    printf 'monitor: feature flags enabled: (none)\n' >&2
  fi
}

repair_local_package_product_link() {
  local pbxproj_path="$1"
  HARNESS_MONITOR_LOCAL_PACKAGE_RELATIVE_PATH="$LOCAL_REGISTRY_PACKAGE_RELATIVE_PATH" \
  HARNESS_MONITOR_LOCAL_PACKAGE_PRODUCT_NAME="$LOCAL_REGISTRY_PRODUCT_NAME" \
    /usr/bin/perl -0pi -e '
      my $package_path = $ENV{HARNESS_MONITOR_LOCAL_PACKAGE_RELATIVE_PATH};
      my $product_name = $ENV{HARNESS_MONITOR_LOCAL_PACKAGE_PRODUCT_NAME};
      my $package_comment = "/* XCLocalSwiftPackageReference \"$package_path\" */";
      my ($package_id) = $_ =~ /([A-F0-9]+) \Q$package_comment\E = \{\n\t\t\tisa = XCLocalSwiftPackageReference;/s
        or die "missing local package reference for $package_path\n";
      my $package_line = "\t\t\tpackage = $package_id $package_comment;\n";
      my $product_block = qr/\t\t[A-F0-9]+ \/\* \Q$product_name\E \*\/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;\n/s;

      if ($_ !~ /$product_block\Q$package_line\E\t\t\tproductName = \Q$product_name\E;\n/s) {
        s/($product_block)(\t\t\tproductName = \Q$product_name\E;\n)/$1$package_line$2/s
          or die "missing package product dependency for $product_name\n";
      }
    ' "$pbxproj_path"
}

normalize_shared_schemes() {
  trim_line() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
  }

  normalize_scheme_line() {
    local line="$1"
    line="${line/version = \"1.7\"/version = \"1.3\"}"
    line="${line/BuildableName = \"HarnessMonitor.app\"/BuildableName = \"Harness Monitor.app\"}"
    line="${line/BuildableName = \"HarnessMonitorUITestHost.app\"/BuildableName = \"Harness Monitor UI Testing.app\"}"
    line="${line/ runPostActionsOnFailure = \"NO\"/}"
    line="${line/ onlyGenerateCoverageForSpecifiedTargets = \"NO\"/}"
    printf '%s' "$line"
  }

  collapse_standalone_tag_closer() {
    local line="$1"
    local trimmed_line="$2"

    if [[ "$trimmed_line" != ">" && "$trimmed_line" != "/>" ]]; then
      return 1
    fi

    if (( ${#normalized_lines[@]} == 0 )); then
      return 1
    fi

    local previous_index=$(( ${#normalized_lines[@]} - 1 ))
    local previous_line="${normalized_lines[previous_index]}"
    local trimmed_previous_line
    trimmed_previous_line="$(trim_line "$previous_line")"

    if [[ -z "$trimmed_previous_line" ]] \
      || [[ "$trimmed_previous_line" == \</* ]] \
      || [[ "$trimmed_previous_line" == *">" ]] \
      || [[ "$trimmed_previous_line" == *"?>" ]] \
      || [[ "$trimmed_previous_line" == "<!--"* ]]; then
      return 1
    fi

    normalized_lines[previous_index]="${previous_line}${trimmed_line}"
    return 0
  }

  reorder_test_action_environment() {
    local index
    local test_action_started=0
    local testables_start=-1
    local testables_end=-1
    local environment_start=-1
    local environment_end=-1

    for index in "${!normalized_lines[@]}"; do
      local line="${normalized_lines[index]}"
      local trimmed_line
      trimmed_line="$(trim_line "$line")"

      if (( test_action_started == 0 )); then
        if [[ "$line" == *"<TestAction"* ]]; then
          test_action_started=1
        fi
        continue
      fi

      if (( testables_start < 0 )) && [[ "$trimmed_line" == "<Testables>" ]]; then
        testables_start=$index
        continue
      fi

      if (( testables_start >= 0 && testables_end < 0 )) && [[ "$trimmed_line" == "</Testables>" ]]; then
        testables_end=$index
        continue
      fi

      if (( environment_start < 0 )) && [[ "$trimmed_line" == "<EnvironmentVariables>" ]]; then
        environment_start=$index
        continue
      fi

      if (( environment_start >= 0 && environment_end < 0 )) && [[ "$trimmed_line" == "</EnvironmentVariables>" ]]; then
        environment_end=$index
        continue
      fi

      if [[ "$line" == *"</TestAction>"* ]]; then
        break
      fi
    done

    if (( testables_start < 0 || testables_end < 0 || environment_start < 0 || environment_end < 0 || environment_start < testables_start )); then
      return
    fi

    local reordered_lines=()

    for (( index = 0; index < testables_start; index += 1 )); do
      reordered_lines+=("${normalized_lines[index]}")
    done

    for (( index = environment_start; index <= environment_end; index += 1 )); do
      reordered_lines+=("${normalized_lines[index]}")
    done

    for (( index = testables_end + 1; index < environment_start; index += 1 )); do
      reordered_lines+=("${normalized_lines[index]}")
    done

    for (( index = testables_start; index <= testables_end; index += 1 )); do
      reordered_lines+=("${normalized_lines[index]}")
    done

    for (( index = environment_end + 1; index < ${#normalized_lines[@]}; index += 1 )); do
      reordered_lines+=("${normalized_lines[index]}")
    done

    normalized_lines=("${reordered_lines[@]}")
  }

  local scheme_path
  for scheme_path in "$SCHEMES_DIR"/*.xcscheme; do
    [ -e "$scheme_path" ] || continue

    local raw_lines=()
    while IFS= read -r line || [ -n "$line" ]; do
      raw_lines+=("$line")
    done < "$scheme_path"

    local normalized_lines=()
    local index=0

    while (( index < ${#raw_lines[@]} )); do
      local line
      line="$(normalize_scheme_line "${raw_lines[index]}")"

      local trimmed_line
      trimmed_line="$(trim_line "$line")"

      if collapse_standalone_tag_closer "$line" "$trimmed_line"; then
        (( index += 1 ))
        continue
      fi

      if [[ "$trimmed_line" == "<CommandLineArguments>" ]]; then
        local next_line=""
        if (( index + 1 < ${#raw_lines[@]} )); then
          next_line="$(normalize_scheme_line "${raw_lines[index + 1]}")"
        fi

        if [[ "$(trim_line "$next_line")" == "</CommandLineArguments>" ]]; then
          (( index += 2 ))
          continue
        fi
      fi

      if [[ "$line" == *"<TestableReference"* ]]; then
        local testable_lines=()
        local ui_test_bundle=0

        while (( index < ${#raw_lines[@]} )); do
          local testable_line
          testable_line="$(normalize_scheme_line "${raw_lines[index]}")"
          local trimmed_testable_line
          trimmed_testable_line="$(trim_line "$testable_line")"

          if [[ "$trimmed_testable_line" == ">" || "$trimmed_testable_line" == "/>" ]]; then
            if (( ${#testable_lines[@]} > 0 )); then
              local previous_testable_index=$(( ${#testable_lines[@]} - 1 ))
              local previous_testable_line="${testable_lines[previous_testable_index]}"
              local trimmed_previous_testable_line
              trimmed_previous_testable_line="$(trim_line "$previous_testable_line")"

              if [[ -n "$trimmed_previous_testable_line" ]] \
                && [[ "$trimmed_previous_testable_line" != \</* ]] \
                && [[ "$trimmed_previous_testable_line" != *">" ]] \
                && [[ "$trimmed_previous_testable_line" != *"?>" ]] \
                && [[ "$trimmed_previous_testable_line" != "<!--"* ]]; then
                testable_lines[previous_testable_index]="${previous_testable_line}${trimmed_testable_line}"
                if [[ "$testable_line" == *"</TestableReference>"* ]]; then
                  break
                fi
                (( index += 1 ))
                continue
              fi
            fi
          fi

          if [[ "$testable_line" == *'BuildableName = "HarnessMonitorUITests.xctest"'* ]] || [[ "$testable_line" == *'BuildableName = "HarnessMonitorAgentsE2ETests.xctest"'* ]]; then
            ui_test_bundle=1
          fi
          testable_lines+=("$testable_line")
          if [[ "$testable_line" == *"</TestableReference>"* ]]; then
            break
          fi
          (( index += 1 ))
        done

        local testable_line
        for testable_line in "${testable_lines[@]}"; do
          if (( ui_test_bundle )); then
            testable_line="${testable_line/ parallelizable = \"NO\"/}"
          fi

          local trimmed_testable_line
          trimmed_testable_line="$(trim_line "$testable_line")"
          if collapse_standalone_tag_closer "$testable_line" "$trimmed_testable_line"; then
            continue
          fi

          normalized_lines+=("$testable_line")
        done

        (( index += 1 ))
        continue
      fi

      normalized_lines+=("$line")
      (( index += 1 ))
    done

    reorder_test_action_environment

    local temp_file
    temp_file="$(mktemp)"
    printf '%s\n' "${normalized_lines[@]}" > "$temp_file"
    mv "$temp_file" "$scheme_path"
  done
}

if [ "$NORMALIZE_ONLY" != "1" ]; then
  if [ -z "${XCODEGEN_BIN}" ]; then
    echo "xcodegen is required on PATH or via XCODEGEN_BIN" >&2
    exit 1
  fi

  enforce_supported_xcodegen_version

  compose_feature_spec

  # XcodeGen preserves pre-existing shared scheme files instead of replacing them,
  # so stale XML can survive regeneration and keep showing up as dirty churn.
  rm -rf "$SCHEMES_DIR"

  "$XCODEGEN_BIN" generate --spec "$MERGED_SPEC" --project "$ROOT"

  # XcodeGen does not expose LastUpgradeCheck or product bundle file-reference names.
  # Apply these as post-generation patches so they survive regeneration.

  # Xcode 26 compatibility version (1430 = Xcode 14.3, 2640 = Xcode 26.0)
  # Use extended regex to match both spaced (= "1430") and compact (="1430") attribute formats.
  sed -i '' -E 's/LastUpgradeCheck *= *1430/LastUpgradeCheck = 2640/g' "$PBXPROJ"

  # Product bundle names: XcodeGen derives them from the target name, not PRODUCT_NAME.
  # The shipped app and UI test host have display names with spaces; fix the file references.
  sed -i '' \
    -e 's|/\* HarnessMonitor\.app \*/|/* Harness Monitor.app */|g' \
    -e 's|path = HarnessMonitor\.app;|path = "Harness Monitor.app";|g' \
    -e 's|/\* HarnessMonitorUITestHost\.app \*/|/* Harness Monitor UI Testing.app */|g' \
    -e 's|path = HarnessMonitorUITestHost\.app;|path = "Harness Monitor UI Testing.app";|g' \
    "$PBXPROJ"

  # XcodeGen omits the back-reference from the local package product to its
  # XCLocalSwiftPackageReference. Repair it so Xcode resolves the local package.
  repair_local_package_product_link "$PBXPROJ"
fi

# Scheme files carry the same LastUpgradeVersion attribute.
for scheme in "$SCHEMES_DIR"/*.xcscheme; do
  sed -i '' -E 's/LastUpgradeVersion *= *"1430"/LastUpgradeVersion = "2640"/g' "$scheme"
done

normalize_shared_schemes

if [ "$NORMALIZE_ONLY" != "1" ] && [ "${HARNESS_MONITOR_SKIP_VERSION_SYNC:-0}" != "1" ]; then
  "$REPO_ROOT/scripts/version.sh" sync-monitor
fi

write_build_server_config() {
  local config_path="$1"
  local argv_path="$2"
  local workspace_path="$3"
  local build_root_path="$4"

  cat > "$config_path" <<EOF
{
  "name": "xcode build server",
  "version": "${BUILD_SERVER_VERSION}",
  "bspVersion": "2.2.0",
  "languages": [
    "c",
    "cpp",
    "objective-c",
    "objective-cpp",
    "swift"
  ],
  "argv": [
    "/bin/bash",
    "${argv_path}"
  ],
  "workspace": "${workspace_path}",
  "build_root": "${build_root_path}",
  "scheme": "HarnessMonitor",
  "kind": "xcode"
}
EOF
}

if [ "$NORMALIZE_ONLY" != "1" ]; then
  write_build_server_config \
    "$ROOT/buildServer.json" \
    "./Scripts/run-xcode-build-server.sh" \
    "HarnessMonitor.xcodeproj/project.xcworkspace" \
    "../../xcode-derived"

  write_build_server_config \
    "$REPO_ROOT/buildServer.json" \
    "./apps/harness-monitor-macos/Scripts/run-xcode-build-server.sh" \
    "apps/harness-monitor-macos/HarnessMonitor.xcodeproj/project.xcworkspace" \
    "xcode-derived"
fi
