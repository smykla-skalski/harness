#!/bin/bash

# Sourceable helper that runs the cargo build for the harness daemon helper.
# Callers must have sourced lib/daemon-bundle-env.sh first so resolve_repo_root
# and resolve_cargo_target_dir are available.
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
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

# Read the pinned toolchain channel from rust-toolchain.toml. Empty output
# means "no pin"; callers treat empty as "skip enforcement".
resolve_pinned_toolchain_channel() {
  local repo_root toolchain_file
  repo_root="${1:-$(resolve_repo_root)}"
  toolchain_file="$repo_root/rust-toolchain.toml"
  [ -r "$toolchain_file" ] || return 0
  /usr/bin/awk -F '=' '
    /^[[:space:]]*\[toolchain\][[:space:]]*$/ { in_section = 1; next }
    /^[[:space:]]*\[/ && in_section { exit }
    in_section && $1 ~ /^[[:space:]]*channel[[:space:]]*$/ {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$toolchain_file"
}

# Run cargo with a sanitized environment for the daemon helper build. Every
# env var stripped here is one that historically caused fingerprint drift in
# `.cache/harness-monitor-xcode-daemon/`:
#   - RUSTFLAGS / CARGO_BUILD_RUSTFLAGS / CARGO_ENCODED_RUSTFLAGS: any one of
#     these replaces `[build] rustflags` from `.cargo/config.toml`. A doubled
#     `--cfg tokio_unstable` propagated by a wrapper produced three distinct
#     fingerprints per crate in one day.
#   - CARGO_BIN / RUSTC: re-resolution would bypass the rustup proxy.
#   - SWIFT_DEBUG_INFORMATION_*: Xcode injects these and standalone swift CLI
#     entrypoints warn on them.
# `RUSTUP_TOOLCHAIN` is replaced with the pinned channel so Xcode UI (no mise
# activation) and `mise run` (mise exports its own) agree.
run_daemon_cargo() {
  local pinned_channel="$1"
  shift
  local -a env_args=(
    -u SWIFT_DEBUG_INFORMATION_FORMAT
    -u SWIFT_DEBUG_INFORMATION_VERSION
    -u RUSTFLAGS
    -u CARGO_BUILD_RUSTFLAGS
    -u CARGO_ENCODED_RUSTFLAGS
    -u CARGO_BIN
    -u RUSTC
  )
  if [ -n "$pinned_channel" ]; then
    env_args+=("RUSTUP_TOOLCHAIN=$pinned_channel")
  else
    env_args+=(-u RUSTUP_TOOLCHAIN)
  fi
  env "${env_args[@]}" "$@"
}

# Hard-fail when the rustup proxy resolves to a toolchain that does not match
# rust-toolchain.toml. Catches stray RUSTUP_TOOLCHAIN overrides, a Homebrew
# cargo on PATH ahead of the rustup proxy, or a worktree that drifted away
# from the pin. The alternative is a silent 5-15 min full rebuild.
assert_daemon_cargo_toolchain() {
  local cargo_bin="$1"
  local pinned_channel="$2"
  local repo_root="$3"
  [ -n "$pinned_channel" ] || return 0

  # No rustup peer next to this cargo (e.g., Homebrew cargo): can't verify
  # the channel, but the build will then use whatever rustc Homebrew ships,
  # which is exactly what we want to flag.
  local rustup_bin
  rustup_bin="$(dirname "$cargo_bin")/rustup"
  if [ ! -x "$rustup_bin" ]; then
    printf 'daemon-cargo-build: cargo "%s" has no rustup peer; rust-toolchain.toml pin "%s" cannot be enforced.\n' \
      "$cargo_bin" "$pinned_channel" >&2
    printf '  Hint: install rustup (https://rustup.rs) and remove any Homebrew rust that shadows ~/.cargo/bin.\n' >&2
    exit 1
  fi

  local active_toolchain
  active_toolchain="$(
    cd "$repo_root" 2>/dev/null && \
    env -u RUSTUP_TOOLCHAIN RUSTUP_TOOLCHAIN="$pinned_channel" \
      "$rustup_bin" show active-toolchain 2>/dev/null | /usr/bin/awk '{print $1; exit}'
  )"
  if [ -z "$active_toolchain" ]; then
    printf 'daemon-cargo-build: rustup at "%s" could not report an active toolchain.\n' "$rustup_bin" >&2
    exit 1
  fi

  case "$active_toolchain" in
    "$pinned_channel"|"$pinned_channel"-*) return 0 ;;
  esac

  printf 'daemon-cargo-build: rustup active toolchain "%s" does not match the channel "%s" pinned in rust-toolchain.toml.\n' \
    "$active_toolchain" "$pinned_channel" >&2
  printf '  This would silently invalidate the shared daemon cargo cache and trigger a full rebuild.\n' >&2
  printf '  Hint: ensure rust-toolchain.toml is present in %s, that the rustup proxy is on PATH,\n' "$repo_root" >&2
  printf '        and that no parent env exports a conflicting RUSTUP_TOOLCHAIN.\n' >&2
  exit 1
}

# Persist the (rustc, rustflags, wrapper) tuple alongside the cache so a
# future drift surfaces with a one-line warning instead of requiring JSON
# archaeology on .fingerprint/. Compares against the previous tuple and
# logs a diff when any dimension changes -- the cache contents stay valid
# only when the tuple is stable.
#
# Records the *effective* env that cargo will see, not the script's shell
# env. `run_daemon_cargo` strips RUSTFLAGS variants and sets RUSTUP_TOOLCHAIN
# from the pinned channel, so the recorded tuple must reflect those overrides
# or every Xcode-UI run (which has no mise-injected RUSTUP_TOOLCHAIN) would
# diff against every terminal run (which has one) and report false drift.
record_daemon_build_context() {
  local cargo_bin="$1"
  local target_dir="$2"
  local pinned_channel="${3:-}"
  /bin/mkdir -p "$target_dir"
  local context_path="$target_dir/.daemon-context"
  local summary
  summary="$(
    printf 'cargo=%s\n' "$cargo_bin"
    env "RUSTUP_TOOLCHAIN=${pinned_channel:-${RUSTUP_TOOLCHAIN:-}}" "$cargo_bin" --version --verbose 2>/dev/null | /usr/bin/sed -n '1,8p'
    printf 'RUSTUP_TOOLCHAIN=%s\n' "$pinned_channel"
    printf 'RUSTC_WRAPPER=%s\n' "${RUSTC_WRAPPER:-}"
    printf 'RUSTFLAGS=\n'
    printf 'CARGO_ENCODED_RUSTFLAGS=\n'
    printf 'CARGO_BUILD_RUSTFLAGS=\n'
  )"
  if [ -r "$context_path" ]; then
    local previous
    previous="$(/bin/cat "$context_path")"
    if [ "$previous" != "$summary" ]; then
      printf 'daemon-cargo-build: build context changed since last run; the cache at\n' >&2
      printf '  %s\n' "$target_dir" >&2
      printf 'will be partially invalidated. Context diff:\n' >&2
      /usr/bin/diff <(printf '%s\n' "$previous") <(printf '%s\n' "$summary") >&2 || true
    fi
  fi
  printf '%s\n' "$summary" >"$context_path"
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

  local pinned_channel
  pinned_channel="$(resolve_pinned_toolchain_channel "$repo_root")"
  assert_daemon_cargo_toolchain "$cargo_bin" "$pinned_channel" "$repo_root"

  local daemon_info_digest
  daemon_info_digest="$(/usr/bin/shasum -a 256 "$daemon_info_plist" | /usr/bin/awk '{print $1}')"

  local daemon_info_link_plist="$target_dir/daemon-info/io.harnessmonitor.daemon.$daemon_info_digest.Info.plist"
  /bin/mkdir -p "$(dirname "$daemon_info_link_plist")"
  /bin/cp "$daemon_info_plist" "$daemon_info_link_plist"
  if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$daemon_info_link_plist"
  fi

  record_daemon_build_context "$cargo_bin" "$target_dir" "$pinned_channel"

  (
    cd "$repo_root" || exit 1
    CARGO_TARGET_DIR="$target_dir" run_daemon_cargo "$pinned_channel" \
      "$cargo_bin" "${cargo_args[@]}" -- \
      -C "link-arg=-Wl,-sectcreate,__TEXT,__info_plist,$daemon_info_link_plist" \
      -C "link-arg=-Wl,-no_compact_unwind"
  )

  printf '%s\n' "$(daemon_binary_output_path)"
}
