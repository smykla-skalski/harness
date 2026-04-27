#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh
source "$ROOT/apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh"
sanitize_xcode_only_swift_environment
CARGO_TOML="$ROOT/Cargo.toml"
TESTKIT_CARGO_TOML="$ROOT/testkit/Cargo.toml"
CARGO_LOCK="$ROOT/Cargo.lock"
MONITOR_BUILD_SETTINGS="$ROOT/apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift"
MONITOR_DAEMON_INFO_PLIST="$ROOT/apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"
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

set_manifest_package_version() {
  local manifest="$1"
  local package_name="$2"
  local version="$3"

  PACKAGE_NAME="$package_name" NEW_VERSION="$version" perl -0pi -e '
    my $count = s/(\[package\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = ")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/se;
    die "failed to update $ENV{PACKAGE_NAME} version in $ARGV\n" unless $count;
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
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$MONITOR_DAEMON_INFO_PLIST"
}

set_daemon_plist_build_version() {
  local version="$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$MONITOR_DAEMON_INFO_PLIST"
}

sync_monitor() {
  local version="$1"
  set_build_settings_marketing_version "$version"
  set_build_settings_current_version "$version"
  set_daemon_plist_version "$version"
  set_daemon_plist_build_version "$version"
}

validate_semver() {
  local version="$1"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    die "invalid version: $version"
  fi
}

check_sync() {
  local version testkit_version lock_harness_version lock_testkit_version
  local marketing_version current_version daemon_version daemon_build_version
  local -a errors=()

  version="$(canonical_version)"
  testkit_version="$(manifest_package_version "$TESTKIT_CARGO_TOML" "harness-testkit")"
  lock_harness_version="$(lock_package_version "$CARGO_LOCK" "harness")"
  lock_testkit_version="$(lock_package_version "$CARGO_LOCK" "harness-testkit")"
  marketing_version="$(build_settings_marketing_version)"
  current_version="$(build_settings_current_version)"
  daemon_version="$(daemon_plist_version)"
  daemon_build_version="$(daemon_plist_build_version)"

  [ "$testkit_version" = "$version" ] || errors+=("testkit/Cargo.toml version $testkit_version != Cargo.toml version $version")
  [ "$lock_harness_version" = "$version" ] || errors+=("Cargo.lock harness version $lock_harness_version != Cargo.toml version $version")
  [ "$lock_testkit_version" = "$version" ] || errors+=("Cargo.lock harness-testkit version $lock_testkit_version != Cargo.toml version $version")
  [ "$marketing_version" = "$version" ] || errors+=("apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift MARKETING_VERSION $marketing_version != Cargo.toml version $version")
  [ "$current_version" = "$version" ] || errors+=("apps/harness-monitor-macos/Tuist/ProjectDescriptionHelpers/BuildSettings.swift CURRENT_PROJECT_VERSION $current_version != Cargo.toml version $version")
  [ "$daemon_version" = "$version" ] || errors+=("apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist version $daemon_version != Cargo.toml version $version")
  [ "$daemon_build_version" = "$version" ] || errors+=("apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist build version $daemon_build_version != Cargo.toml version $version")

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

  set_manifest_package_version "$TESTKIT_CARGO_TOML" "harness-testkit" "$version"
  set_lock_package_version "harness" "$version"
  set_lock_package_version "harness-testkit" "$version"
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
