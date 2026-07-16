#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcode-version.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/xcode-version.sh"
sanitize_xcode_only_swift_environment
CARGO_TOML="$ROOT/Cargo.toml"
TESTKIT_CARGO_TOML="$ROOT/testkit/Cargo.toml"
AFF_CARGO_TOML="$ROOT/aff/Cargo.toml"
CORE_PACKAGE_MANIFESTS=(
  "$ROOT/crates/harness-command/Cargo.toml"
  "$ROOT/crates/harness-daemon-client/Cargo.toml"
  "$ROOT/crates/harness-daemon/Cargo.toml"
  "$ROOT/crates/harness-bridge/Cargo.toml"
  "$ROOT/crates/harness-mcp/Cargo.toml"
  "$ROOT/crates/harness-hook/Cargo.toml"
  "$ROOT/crates/harness-protocol/Cargo.toml"
  "$ROOT/crates/harness-systemd/Cargo.toml"
  "$ROOT/crates/harness-telemetry/Cargo.toml"
)
CORE_PACKAGE_NAMES=(
  "harness-command"
  "harness-daemon-client"
  "harness-daemon"
  "harness-bridge"
  "harness-mcp"
  "harness-hook"
  "harness-protocol"
  "harness-systemd"
  "harness-telemetry"
)
CARGO_LOCK="$ROOT/Cargo.lock"
MONITOR_APP_ROOT="$ROOT/apps/harness-monitor"
MONITOR_BUILD_SETTINGS="$ROOT/apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift"
MONITOR_DAEMON_INFO_PLIST="$ROOT/apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"
MONITOR_GENERATED_PBXPROJ="$MONITOR_APP_ROOT/HarnessMonitor.xcodeproj/project.pbxproj"
MONITOR_TUIST_PATCHER="$MONITOR_APP_ROOT/Scripts/patch-tuist-pbxproj.py"
MONITOR_DEFAULT_LAST_UPGRADE_CHECK="$(harness_monitor_default_xcode_upgrade_check)"
MONITOR_LAST_UPGRADE_CHECK="${HARNESS_MONITOR_LAST_UPGRADE_CHECK:-$MONITOR_DEFAULT_LAST_UPGRADE_CHECK}"
MONITOR_LAST_SWIFT_UPDATE_CHECK="${HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK:-$MONITOR_LAST_UPGRADE_CHECK}"
MONITOR_PROJECT_OBJECT_VERSION="${HARNESS_MONITOR_PROJECT_OBJECT_VERSION:-77}"
MONITOR_PREFERRED_PROJECT_OBJECT_VERSION="${HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION:-$MONITOR_PROJECT_OBJECT_VERSION}"
SARIF_OUTPUT_RS="$ROOT/src/observe/output.rs"

usage() {
  cat <<'EOF'
Usage:
  scripts/version.sh show
  scripts/version.sh check
  scripts/version.sh sync
  scripts/version.sh set <version>
  scripts/version.sh sync-monitor

Commands:
  show         Print the canonical harness package version from Cargo.toml.
  check        Verify all derived version surfaces are in sync.
  sync         Sync all derived version surfaces from Cargo.toml.
  set          Update Cargo.toml to <version> and sync all derived surfaces.
  sync-monitor Sync only the Harness Monitor derived version surfaces.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

canonical_version() {
  perl -0ne '
    if (/\[package\]\s*name = "harness"\s*version = "([^"]+)"/s) {
      print "$1\n";
      exit 0;
    }
    exit 1;
  ' "$CARGO_TOML"
}

manifest_package_version() {
  local manifest="$1"
  local package_name="$2"
  PACKAGE_NAME="$package_name" perl -0ne '
    if (/\[package\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = "([^"]+)"/s) {
      print "$1\n";
      exit 0;
    }
    exit 1;
  ' "$manifest"
}

manifest_harness_dependency_versions() {
  local manifest="$1"
  perl -ne '
    if (/^(harness-[A-Za-z0-9-]+)\s*=\s*\{([^}]*)\}/) {
      my ($name, $attributes) = ($1, $2);
      my $version = $attributes =~ /\bversion\s*=\s*"([^"]+)"/
        ? $1
        : "<missing>";
      print "$name\t$version\n";
    }
  ' "$manifest"
}

is_core_package_name() {
  local candidate="$1"
  local package_name
  for package_name in "${CORE_PACKAGE_NAMES[@]}"; do
    [ "$candidate" = "$package_name" ] && return 0
  done
  return 1
}

manifest_has_dependency() {
  local manifest="$1"
  local dependency_name="$2"
  DEPENDENCY_NAME="$dependency_name" perl -ne '
    BEGIN { $found = 0; }
    if (/^\Q$ENV{DEPENDENCY_NAME}\E\s*=/) {
      $found = 1;
      last;
    }
    END { exit($found ? 0 : 1); }
  ' "$manifest"
}

lock_package_version() {
  local lockfile="$1"
  local package_name="$2"
  PACKAGE_NAME="$package_name" perl -0ne '
    if (/\[\[package\]\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = "([^"]+)"/s) {
      print "$1\n";
      exit 0;
    }
    exit 1;
  ' "$lockfile"
}

build_settings_marketing_version() {
  perl -ne '
    if (m{"MARKETING_VERSION"\s*:\s*"([^"]+)".*VERSION_MARKER_MARKETING}) {
      print "$1\n";
      exit 0;
    }
  ' "$MONITOR_BUILD_SETTINGS"
}

build_settings_current_version() {
  perl -ne '
    if (m{"CURRENT_PROJECT_VERSION"\s*:\s*"([^"]+)".*VERSION_MARKER_CURRENT}) {
      print "$1\n";
      exit 0;
    }
  ' "$MONITOR_BUILD_SETTINGS"
}

daemon_plist_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MONITOR_DAEMON_INFO_PLIST"
}

daemon_plist_build_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MONITOR_DAEMON_INFO_PLIST"
}

generated_monitor_pbxproj_exists() {
  [ -f "$MONITOR_GENERATED_PBXPROJ" ]
}

generated_pbxproj_marketing_versions() {
  perl -ne '
    if (m{^\s*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.-]+)?);$}) {
      print "$1\n";
    }
  ' "$MONITOR_GENERATED_PBXPROJ"
}

generated_pbxproj_current_versions() {
  perl -ne '
    if (m{^\s*CURRENT_PROJECT_VERSION = ([0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.-]+)?);$}) {
      print "$1\n";
    }
  ' "$MONITOR_GENERATED_PBXPROJ"
}

set_manifest_package_version() {
  local manifest="$1"
  local package_name="$2"
  local version="$3"

  PACKAGE_NAME="$package_name" NEW_VERSION="$version" perl -0pi -e '
    my $count = s/(\[package\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = ")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/se;
    die "failed to update $ENV{PACKAGE_NAME} version in $ARGV\n" unless $count;
  ' "$manifest"
}

set_manifest_dependency_version() {
  local manifest="$1"
  local dependency_name="$2"
  local version="$3"

  DEPENDENCY_NAME="$dependency_name" NEW_VERSION="$version" perl -0pi -e '
    my $count = s/(^\Q$ENV{DEPENDENCY_NAME}\E\s*=\s*\{[^}\n]*\bversion\s*=\s*")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/gme;
    die "failed to update $ENV{DEPENDENCY_NAME} dependency version in $ARGV\n" unless $count;
  ' "$manifest"
}

set_lock_package_version() {
  local package_name="$1"
  local version="$2"

  PACKAGE_NAME="$package_name" NEW_VERSION="$version" perl -0pi -e '
    my $count = s/(\[\[package\]\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = ")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/se;
    die "failed to update $ENV{PACKAGE_NAME} version in $ARGV\n" unless $count;
  ' "$CARGO_LOCK"
}

set_build_settings_marketing_version() {
  local version="$1"

  NEW_VERSION="$version" perl -pi -e '
    if (m{VERSION_MARKER_MARKETING}) {
      my $count = s{("MARKETING_VERSION"\s*:\s*")[^"]+(")}{$1.$ENV{NEW_VERSION}.$2}e;
      die "failed to update MARKETING_VERSION in $ARGV\n" unless $count;
    }
  ' "$MONITOR_BUILD_SETTINGS"
}

set_build_settings_current_version() {
  local version="$1"

  NEW_VERSION="$version" perl -pi -e '
    if (m{VERSION_MARKER_CURRENT}) {
      my $count = s{("CURRENT_PROJECT_VERSION"\s*:\s*")[^"]+(")}{$1.$ENV{NEW_VERSION}.$2}e;
      die "failed to update CURRENT_PROJECT_VERSION in $ARGV\n" unless $count;
    }
  ' "$MONITOR_BUILD_SETTINGS"
}

set_daemon_plist_version() {
  local version="$1"
  PLIST_KEY="CFBundleShortVersionString" NEW_VERSION="$version" perl -0pi -e '
    my $count = s{(<key>\Q$ENV{PLIST_KEY}\E</key>\s*<string>)[^<]+(</string>)}{$1.$ENV{NEW_VERSION}.$2}e;
    die "failed to update $ENV{PLIST_KEY} in $ARGV\n" unless $count;
  ' "$MONITOR_DAEMON_INFO_PLIST"
}

set_daemon_plist_build_version() {
  local version="$1"
  PLIST_KEY="CFBundleVersion" NEW_VERSION="$version" perl -0pi -e '
    my $count = s{(<key>\Q$ENV{PLIST_KEY}\E</key>\s*<string>)[^<]+(</string>)}{$1.$ENV{NEW_VERSION}.$2}e;
    die "failed to update $ENV{PLIST_KEY} in $ARGV\n" unless $count;
  ' "$MONITOR_DAEMON_INFO_PLIST"
}

sync_generated_monitor_project() {
  local version="$1"

  if ! generated_monitor_pbxproj_exists; then
    return
  fi

  HARNESS_MONITOR_PBXPROJ="$MONITOR_GENERATED_PBXPROJ" \
  HARNESS_MONITOR_LAST_UPGRADE_CHECK="$MONITOR_LAST_UPGRADE_CHECK" \
  HARNESS_MONITOR_LAST_SWIFT_UPDATE_CHECK="$MONITOR_LAST_SWIFT_UPDATE_CHECK" \
  HARNESS_MONITOR_PROJECT_OBJECT_VERSION="$MONITOR_PROJECT_OBJECT_VERSION" \
  HARNESS_MONITOR_PREFERRED_PROJECT_OBJECT_VERSION="$MONITOR_PREFERRED_PROJECT_OBJECT_VERSION" \
  HARNESS_MONITOR_MARKETING_VERSION="$version" \
  HARNESS_MONITOR_CURRENT_PROJECT_VERSION="$version" \
  HARNESS_MONITOR_APP_ROOT="$MONITOR_APP_ROOT" \
  HARNESS_MONITOR_REPO_ROOT="$ROOT" \
    /usr/bin/python3 "$MONITOR_TUIST_PATCHER"
}

sync_monitor() {
  local version="$1"
  set_build_settings_marketing_version "$version"
  set_build_settings_current_version "$version"
  set_daemon_plist_version "$version"
  set_daemon_plist_build_version "$version"
  sync_generated_monitor_project "$version"
}

validate_semver() {
  local version="$1"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    die "invalid version: $version"
  fi
}

check_sync() {
  local version testkit_version aff_version
  local lock_harness_version lock_testkit_version lock_aff_version
  local marketing_version current_version daemon_version daemon_build_version
  local generated_marketing_version generated_current_version
  local -a generated_marketing_versions=()
  local -a generated_current_versions=()
  local -a errors=()
  local index package_name package_version lock_package_version_value
  local dependency_manifest dependency_name dependency_version

  version="$(canonical_version)"
  testkit_version="$(manifest_package_version "$TESTKIT_CARGO_TOML" "harness-testkit")"
  aff_version="$(manifest_package_version "$AFF_CARGO_TOML" "aff")"
  lock_harness_version="$(lock_package_version "$CARGO_LOCK" "harness")"
  lock_testkit_version="$(lock_package_version "$CARGO_LOCK" "harness-testkit")"
  lock_aff_version="$(lock_package_version "$CARGO_LOCK" "aff")"
  marketing_version="$(build_settings_marketing_version)"
  current_version="$(build_settings_current_version)"
  if [ "$(uname -s)" = "Darwin" ]; then
    daemon_version="$(daemon_plist_version)"
    daemon_build_version="$(daemon_plist_build_version)"
  else
    echo "version: skipping daemon plist version check off macOS"
  fi

  [ "$testkit_version" = "$version" ] || errors+=("testkit/Cargo.toml version $testkit_version != Cargo.toml version $version")
  [ "$aff_version" = "$version" ] || errors+=("aff/Cargo.toml version $aff_version != Cargo.toml version $version")
  [ "$lock_harness_version" = "$version" ] || errors+=("Cargo.lock harness version $lock_harness_version != Cargo.toml version $version")
  [ "$lock_testkit_version" = "$version" ] || errors+=("Cargo.lock harness-testkit version $lock_testkit_version != Cargo.toml version $version")
  [ "$lock_aff_version" = "$version" ] || errors+=("Cargo.lock aff version $lock_aff_version != Cargo.toml version $version")
  for index in "${!CORE_PACKAGE_MANIFESTS[@]}"; do
    package_name="${CORE_PACKAGE_NAMES[$index]}"
    package_version="$(manifest_package_version "${CORE_PACKAGE_MANIFESTS[$index]}" "$package_name")"
    lock_package_version_value="$(lock_package_version "$CARGO_LOCK" "$package_name")"
    [ "$package_version" = "$version" ] || errors+=("${CORE_PACKAGE_MANIFESTS[$index]#"$ROOT/"} version $package_version != Cargo.toml version $version")
    [ "$lock_package_version_value" = "$version" ] || errors+=("Cargo.lock $package_name version $lock_package_version_value != Cargo.toml version $version")
  done
  for dependency_manifest in "$CARGO_TOML" "${CORE_PACKAGE_MANIFESTS[@]}"; do
    while IFS=$'\t' read -r dependency_name dependency_version; do
      is_core_package_name "$dependency_name" || continue
      [ "$dependency_version" = "$version" ] || errors+=("${dependency_manifest#"$ROOT/"} $dependency_name dependency version $dependency_version != Cargo.toml version $version")
    done < <(manifest_harness_dependency_versions "$dependency_manifest")
  done
  [ "$marketing_version" = "$version" ] || errors+=("apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift MARKETING_VERSION $marketing_version != Cargo.toml version $version")
  [ "$current_version" = "$version" ] || errors+=("apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift CURRENT_PROJECT_VERSION $current_version != Cargo.toml version $version")
  if [ "$(uname -s)" = "Darwin" ]; then
    [ "$daemon_version" = "$version" ] || errors+=("apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist version $daemon_version != Cargo.toml version $version")
    [ "$daemon_build_version" = "$version" ] || errors+=("apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist build version $daemon_build_version != Cargo.toml version $version")
  fi

  if generated_monitor_pbxproj_exists; then
    while IFS= read -r generated_marketing_version; do
      generated_marketing_versions+=("$generated_marketing_version")
    done < <(generated_pbxproj_marketing_versions)
    while IFS= read -r generated_current_version; do
      generated_current_versions+=("$generated_current_version")
    done < <(generated_pbxproj_current_versions)

    if [ "${#generated_marketing_versions[@]}" -eq 0 ]; then
      errors+=("apps/harness-monitor/HarnessMonitor.xcodeproj/project.pbxproj is missing semver MARKETING_VERSION entries")
    else
      for generated_marketing_version in "${generated_marketing_versions[@]}"; do
        [ "$generated_marketing_version" = "$version" ] || errors+=("apps/harness-monitor/HarnessMonitor.xcodeproj/project.pbxproj MARKETING_VERSION $generated_marketing_version != Cargo.toml version $version")
      done
    fi

    if [ "${#generated_current_versions[@]}" -eq 0 ]; then
      errors+=("apps/harness-monitor/HarnessMonitor.xcodeproj/project.pbxproj is missing semver CURRENT_PROJECT_VERSION entries")
    else
      for generated_current_version in "${generated_current_versions[@]}"; do
        [ "$generated_current_version" = "$version" ] || errors+=("apps/harness-monitor/HarnessMonitor.xcodeproj/project.pbxproj CURRENT_PROJECT_VERSION $generated_current_version != Cargo.toml version $version")
      done
    fi
  fi

  if ! grep -q 'env!("CARGO_PKG_VERSION")' "$SARIF_OUTPUT_RS"; then
    errors+=("src/observe/output.rs must keep SARIF driver.version sourced from env!(\"CARGO_PKG_VERSION\")")
  fi

  if [ "${#errors[@]}" -gt 0 ]; then
    printf 'version sync check failed:\n' >&2
    for error in "${errors[@]}"; do
      printf '  - %s\n' "$error" >&2
    done
    exit 1
  fi
}

sync_all() {
  local version="$1"
  local dependency_manifest dependency_name index package_name

  set_manifest_package_version "$TESTKIT_CARGO_TOML" "harness-testkit" "$version"
  set_manifest_package_version "$AFF_CARGO_TOML" "aff" "$version"
  for index in "${!CORE_PACKAGE_MANIFESTS[@]}"; do
    package_name="${CORE_PACKAGE_NAMES[$index]}"
    set_manifest_package_version "${CORE_PACKAGE_MANIFESTS[$index]}" "$package_name" "$version"
    set_lock_package_version "$package_name" "$version"
  done
  for dependency_manifest in "$CARGO_TOML" "${CORE_PACKAGE_MANIFESTS[@]}"; do
    for dependency_name in "${CORE_PACKAGE_NAMES[@]}"; do
      if manifest_has_dependency "$dependency_manifest" "$dependency_name"; then
        set_manifest_dependency_version \
          "$dependency_manifest" "$dependency_name" "$version"
      fi
    done
  done
  set_lock_package_version "harness" "$version"
  set_lock_package_version "harness-testkit" "$version"
  set_lock_package_version "aff" "$version"
  sync_monitor "$version"
}

command="${1:-}"

case "$command" in
  show)
    shift
    [ "$#" -eq 0 ] || die "show does not accept arguments"
    canonical_version
    ;;
  check)
    shift
    [ "$#" -eq 0 ] || die "check does not accept arguments"
    check_sync
    ;;
  sync)
    shift
    [ "$#" -eq 0 ] || die "sync does not accept arguments"
    sync_all "$(canonical_version)"
    check_sync
    ;;
  set)
    shift
    [ "$#" -eq 1 ] || die "set requires exactly one version argument"
    validate_semver "$1"
    set_manifest_package_version "$CARGO_TOML" "harness" "$1"
    sync_all "$1"
    check_sync
    ;;
  sync-monitor)
    shift
    [ "$#" -eq 0 ] || die "sync-monitor does not accept arguments"
    sync_monitor "$(canonical_version)"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
