#!/bin/bash

# Sourceable helper that runs the cargo build for the harness daemon helper.
# Callers must have sourced lib/daemon-bundle-env.sh first so resolve_repo_root
# and resolve_cargo_target_dir are available.
# shellcheck source=apps/harness-monitor-macos/Scripts/lib/swift-tool-env.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/swift-tool-env.sh"
sanitize_xcode_only_swift_environment

find_cargo() {
  if [ -n "${CARGO_BIN:-}" ] && [ -x "$CARGO_BIN" ]; then
    printf '%s\n' "$CARGO_BIN"
    return
  fi

  # Prefer the rustup proxy at ~/.cargo/bin/cargo before falling through to
  # `command -v cargo`. The proxy honors rust-toolchain.toml, so the rustc
  # version is identical whether the build runs from Xcode's UI (no mise
  # activation, minimal PATH) or from a terminal `mise run monitor:build`.
  # `command -v cargo` resolves against the caller's PATH and can pick a
  # standalone Homebrew cargo that pins its own rustc and ignores the
  # toolchain file - each switch flips cargo's `rustc` fingerprint and forces
  # a full rebuild of every dependency.
  for candidate in \
    "$HOME/.cargo/bin/cargo" \
    /opt/homebrew/bin/cargo \
    /usr/local/bin/cargo; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return
  fi

  printf 'cargo is required to build the Harness daemon helper. Set CARGO_BIN or HARNESS_MONITOR_DAEMON_BINARY.\n' >&2
  exit 1
}

daemon_build_profile_dir() {
  local configuration="${CONFIGURATION:-Debug}"
  if [ "$configuration" = "Release" ]; then
    printf '%s\n' "release"
  else
    printf '%s\n' "debug"
  fi
}

daemon_binary_output_path() {
  local target_dir profile_dir
  target_dir="$(resolve_cargo_target_dir)"
  profile_dir="$(daemon_build_profile_dir)"
  printf '%s/%s/harness\n' "$target_dir" "$profile_dir"
}

build_daemon_binary() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local target_dir
  target_dir="$(resolve_cargo_target_dir)"

  local profile_dir
  profile_dir="$(daemon_build_profile_dir)"
  local cargo_args=(rustc --bin harness)
  if [ "$profile_dir" = "release" ]; then
    cargo_args+=(--release)
  fi

  local daemon_info_plist="$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist"
  local cargo_bin
  cargo_bin="$(find_cargo)"

  local daemon_info_digest
  daemon_info_digest="$(/usr/bin/shasum -a 256 "$daemon_info_plist" | /usr/bin/awk '{print $1}')"

  local daemon_info_link_plist="$target_dir/daemon-info/io.harnessmonitor.daemon.$daemon_info_digest.Info.plist"
  /bin/mkdir -p "$(dirname "$daemon_info_link_plist")"
  /bin/cp "$daemon_info_plist" "$daemon_info_link_plist"
  if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$daemon_info_link_plist"
  fi

  (
    cd "$repo_root" || exit 1
    CARGO_TARGET_DIR="$target_dir" run_with_sanitized_xcode_only_swift_environment \
      "$cargo_bin" "${cargo_args[@]}" -- \
      -C "link-arg=-Wl,-sectcreate,__TEXT,__info_plist,$daemon_info_link_plist" \
      -C "link-arg=-Wl,-no_compact_unwind"
  )

  printf '%s\n' "$(daemon_binary_output_path)"
}
