#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/swift-tool-env.sh"
# shellcheck source=apps/harness-monitor/Scripts/lib/xcode-version.sh
source "$ROOT/apps/harness-monitor/Scripts/lib/xcode-version.sh"
sanitize_xcode_only_swift_environment
CARGO_TOML="$ROOT/Cargo.toml"
CARGO_LOCK="$ROOT/Cargo.lock"
MISSING_VERSION="<missing>"
# Read from the [workspace] members list rather than kept here. A list written
# out by hand bumps and checks whatever it happened to name the day it was last
# edited, so a crate added afterwards keeps the old version and no gate notices.
WORKSPACE_MANIFESTS=()
WORKSPACE_NAMES=()
WORKSPACE_VERSIONS=()
MONITOR_APP_ROOT="$ROOT/apps/harness-monitor"
MONITOR_BUILD_SETTINGS="$ROOT/apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift"
MONITOR_DAEMON_INFO_PLIST="$ROOT/apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"
OPENAPI_DOCUMENT="$ROOT/docs/api/openapi.json"
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

workspace_member_directories() {
  perl -0ne '
    unless (/^members\s*=\s*\[(.*?)\]/ms) {
      die "failed to read the [workspace] members list from $ARGV\n";
    }
    my $members = $1;
    print "$1\n" while $members =~ /"([^"]+)"/g;
  ' "$CARGO_TOML"
}

manifest_package_identity() {
  perl -0ne '
    if (/\[package\]\s*name = "([^"]+)"\s*version = "([^"]+)"/s) {
      print "$1\t$2\n";
      exit 0;
    }
    exit 1;
  ' "$1"
}

load_workspace_members() {
  local member manifest name version
  WORKSPACE_MANIFESTS=()
  WORKSPACE_NAMES=()
  WORKSPACE_VERSIONS=()
  while IFS= read -r member; do
    if [ "$member" = "." ]; then
      manifest="$CARGO_TOML"
    else
      manifest="$ROOT/${member%/}/Cargo.toml"
    fi
    [ -f "$manifest" ] || die "workspace member $member has no Cargo.toml"
    IFS=$'\t' read -r name version < <(manifest_package_identity "$manifest") ||
      die "failed to read the [package] name and version from $manifest"
    WORKSPACE_MANIFESTS+=("$manifest")
    WORKSPACE_NAMES+=("$name")
    WORKSPACE_VERSIONS+=("$version")
  done < <(workspace_member_directories)
  [ "${#WORKSPACE_NAMES[@]}" -gt 0 ] || die "the [workspace] members list is empty"
}

is_workspace_package_name() {
  local candidate="$1"
  local package_name
  for package_name in "${WORKSPACE_NAMES[@]}"; do
    [ "$candidate" = "$package_name" ] && return 0
  done
  return 1
}

# Reports every dependency a manifest declares, so the caller can tell a stale
# requirement from one written in a shape the in-place rewrite cannot reach.
# The unreachable shapes are reported rather than passed over, because passing
# over a declaration is how the version surfaces drifted apart to begin with.
manifest_dependency_declarations() {
  perl -ne '
    if (/^\s*\[/) {
      $section = "";
      if (/^\s*\[([^\[\]]+)\]\s*$/) {
        $section = $1;
        if (my ($named) = $section =~ /(?:^|\.)(?:dev-|build-)?dependencies\.([A-Za-z0-9_-]+)$/) {
          print "opaque\t$named\tdeclared as its own [$section] table\n";
        }
      }
      next;
    }
    next unless defined $section && $section =~ /(?:^|\.)(?:dev-|build-)?dependencies$/;
    next unless /^([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*$/;
    my ($name, $value) = ($1, $2);
    if ($value =~ /^"([^"]*)"$/) {
      print "version\t$name\t$1\n";
    } elsif ($value =~ /^\{(.*)\}$/) {
      my $attributes = $1;
      if (my ($renamed) = $attributes =~ /\bpackage\s*=\s*"([^"]+)"/) {
        print "opaque\t$renamed\trenamed to $name\n";
      }
      if (my ($version) = $attributes =~ /\bversion\s*=\s*"([^"]+)"/) {
        print "version\t$name\t$version\n";
      }
    } elsif ($value =~ /^\{/) {
      print "opaque\t$name\twritten in a shape this script cannot rewrite in place\n";
    }
  ' "$1"
}

lock_package_version() {
  local lockfile="$1"
  local package_name="$2"
  PACKAGE_NAME="$package_name" MISSING_VERSION="$MISSING_VERSION" perl -0ne '
    if (/\[\[package\]\]\s*name = "\Q$ENV{PACKAGE_NAME}\E"\s*version = "([^"]+)"/s) {
      print "$1\n";
      exit 0;
    }
    print "$ENV{MISSING_VERSION}\n";
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

# Only the `info` block's version, never a `version` property inside a schema.
# Parsed rather than matched: the document carries several `version` keys, and
# a pattern that walks past `info` would report one of those instead. An
# unreadable field says so rather than blaming the version it could not find.
openapi_document_version() {
  python3 - "$OPENAPI_DOCUMENT" <<'PY'
import json
import sys

try:
    version = json.load(open(sys.argv[1], encoding="utf-8"))["info"]["version"]
except (OSError, ValueError, KeyError, TypeError):
    version = None
print(version if isinstance(version, str) and version else "<unreadable info.version>", end="")
PY
}

# The document is generated, so this exists to keep it in step with a version
# bump rather than to edit it. A bump changes nothing else in the output, so
# stamping the field matches what `openapi:generate` would produce; any other
# drift is still the generator's business and `openapi:check` still catches it.
set_openapi_document_version() {
  local version="$1"
  NEW_VERSION="$version" python3 - "$OPENAPI_DOCUMENT" <<'PY'
import json
import os
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    raw = handle.read()
json.loads(raw)["info"]["version"]

# Bound the edit to the `info` object. Several schema properties are also
# called `version`, and an unbounded search would stamp one of those the
# moment `info` stopped carrying the field.
start = raw.index('"info"')
depth = 0
end = None
for index in range(start, len(raw)):
    if raw[index] == "{":
        depth += 1
    elif raw[index] == "}":
        depth -= 1
        if depth == 0:
            end = index
            break
if end is None:
    raise SystemExit(f"failed to bound the info object in {path}")

# Rewritten in place rather than re-dumped, so the generator's formatting
# survives and `openapi:check` does not read the bump as drift.
block, count = re.subn(
    r'("version"\s*:\s*")[^"]*(")',
    lambda match: match.group(1) + os.environ["NEW_VERSION"] + match.group(2),
    raw[start:end],
    count=1,
)
if count != 1:
    raise SystemExit(f"failed to update the info version in {path}")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(raw[:start] + block + raw[end:])
PY
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
    $count += s/(^\Q$ENV{DEPENDENCY_NAME}\E\s*=\s*")[^"]+(")/$1.$ENV{NEW_VERSION}.$2/gme;
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
  local version
  local marketing_version current_version daemon_version daemon_build_version
  local openapi_version
  local generated_marketing_version generated_current_version
  local -a generated_marketing_versions=()
  local -a generated_current_versions=()
  local -a errors=()
  local index manifest package_name package_version lock_version
  local kind dependency_name detail

  version="$(canonical_version)"
  load_workspace_members
  openapi_version="$(openapi_document_version)"
  marketing_version="$(build_settings_marketing_version)"
  current_version="$(build_settings_current_version)"
  if [ "$(uname -s)" = "Darwin" ]; then
    daemon_version="$(daemon_plist_version)"
    daemon_build_version="$(daemon_plist_build_version)"
  else
    echo "version: skipping daemon plist version check off macOS"
  fi

  [ "$openapi_version" = "$version" ] || errors+=("docs/api/openapi.json version $openapi_version != Cargo.toml version $version")
  for index in "${!WORKSPACE_MANIFESTS[@]}"; do
    manifest="${WORKSPACE_MANIFESTS[$index]}"
    package_name="${WORKSPACE_NAMES[$index]}"
    package_version="${WORKSPACE_VERSIONS[$index]}"
    lock_version="$(lock_package_version "$CARGO_LOCK" "$package_name")"
    [ "$package_version" = "$version" ] || errors+=("${manifest#"$ROOT/"} $package_name version $package_version != Cargo.toml version $version")
    [ "$lock_version" = "$version" ] || errors+=("Cargo.lock $package_name version $lock_version != Cargo.toml version $version")
  done
  for manifest in "${WORKSPACE_MANIFESTS[@]}"; do
    while IFS=$'\t' read -r kind dependency_name detail; do
      is_workspace_package_name "$dependency_name" || continue
      if [ "$kind" = "version" ]; then
        [ "$detail" = "$version" ] || errors+=("${manifest#"$ROOT/"} $dependency_name dependency version $detail != Cargo.toml version $version")
      else
        errors+=("${manifest#"$ROOT/"} $dependency_name dependency is $detail")
      fi
    done < <(manifest_dependency_declarations "$manifest")
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
  local index manifest package_name kind dependency_name detail

  load_workspace_members
  for index in "${!WORKSPACE_MANIFESTS[@]}"; do
    package_name="${WORKSPACE_NAMES[$index]}"
    set_manifest_package_version "${WORKSPACE_MANIFESTS[$index]}" "$package_name" "$version"
    set_lock_package_version "$package_name" "$version"
  done
  for manifest in "${WORKSPACE_MANIFESTS[@]}"; do
    while IFS=$'\t' read -r kind dependency_name detail; do
      is_workspace_package_name "$dependency_name" || continue
      [ "$kind" = "version" ] ||
        die "${manifest#"$ROOT/"} $dependency_name dependency is $detail"
      set_manifest_dependency_version "$manifest" "$dependency_name" "$version"
    done < <(manifest_dependency_declarations "$manifest")
  done
  sync_monitor "$version"
  set_openapi_document_version "$version"
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
