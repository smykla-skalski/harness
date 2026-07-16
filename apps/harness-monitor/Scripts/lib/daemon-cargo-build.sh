#!/bin/bash

# Sourceable helper that runs the cargo build for the harness daemon helper.
# Callers must have sourced lib/daemon-bundle-env.sh first so resolve_repo_root
# and resolve_cargo_target_dir are available.
# shellcheck source=apps/harness-monitor/Scripts/lib/swift-tool-env.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/swift-tool-env.sh"
sanitize_xcode_only_swift_environment
DAEMON_INPUT_STATE_HELPER="$(
  CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd
)/daemon-input-state.py"

# Hard-fail when a standalone rust install (Homebrew, MacPorts) is present at
# one of the listed paths. The rustc-cache-wrapper at
# `scripts/rustc-cache-wrapper.sh` invokes sccache, which resolves the inner
# `rustc` via PATH. If PATH puts /opt/homebrew/bin, /usr/local/bin, or
# /opt/local/bin ahead of ~/.cargo/bin, sccache picks the standalone rustc
# (e.g. Homebrew rust 1.95 stable, MacPorts rust) instead of the
# rustup-managed pinned nightly. Cargo's fingerprint then reflects the rustup
# proxy's reported version while the actual binary is built by the standalone
# rustc -- every cross-context build is cold and the shared daemon cargo cache
# thrashes.
# Tests pass the list of paths to probe; production passes the canonical six.
assert_no_standalone_rust() {
  local stray
  for stray in "$@"; do
    if [ -e "$stray" ]; then
      printf 'daemon-cargo-build: standalone rust at "%s" shadows the rustup proxy.\n' "$stray" >&2
      printf '  This silently invalidates the shared daemon cargo cache and forces full rebuilds.\n' >&2
      printf '  Uninstall it (e.g. brew uninstall rust, port uninstall rust) so ~/.cargo/bin/{cargo,rustc} is the sole resolver.\n' >&2
      exit 1
    fi
  done
}

find_cargo() {
  assert_no_standalone_rust \
    /opt/homebrew/bin/rustc \
    /opt/homebrew/bin/cargo \
    /usr/local/bin/rustc \
    /usr/local/bin/cargo \
    /opt/local/bin/rustc \
    /opt/local/bin/cargo

  if [ -n "${CARGO_BIN:-}" ] && [ -x "$CARGO_BIN" ]; then
    printf '%s\n' "$CARGO_BIN"
    return
  fi

  # Prefer the rustup proxy at ~/.cargo/bin/cargo. The proxy honors
  # rust-toolchain.toml, so the rustc version is identical whether the build
  # runs from Xcode's UI (no mise activation, minimal PATH) or from a terminal
  # `mise run monitor:build`. `command -v cargo` resolves against the caller's
  # PATH and could pick whatever shows up first; we trust only the rustup
  # proxy here.
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    printf '%s\n' "$HOME/.cargo/bin/cargo"
    return
  fi

  printf 'daemon-cargo-build: rustup proxy not found at "%s/.cargo/bin/cargo".\n' "$HOME" >&2
  printf '  Install rustup (https://rustup.rs) so the daemon cargo cache stays consistent.\n' >&2
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
#   - non-macOS deployment targets: Xcode exports targets for every platform.
#     aws-lc-sys probes clang and clang rejects conflicting iOS, tvOS, watchOS,
#     xrOS, and DriverKit targets. Keep the macOS deployment target intact.
#   - empty compiler overrides: Xcode exports empty CC settings. cc 1.2.67+
#     treats those as an explicit compiler selection instead of using clang.
# `RUSTUP_TOOLCHAIN` is replaced with the pinned channel so Xcode UI (no mise
# activation) and `mise run` (mise exports its own) agree.
run_daemon_cargo() {
  local pinned_channel="$1"
  shift
  # BSD env (macOS) stops parsing -u/-i flags at the first NAME=value
  # assignment. Group every -u flag first, then every NAME=value, then the
  # command. Putting a NAME=value between two -u flags would cause env to
  # treat the trailing -u as the command to exec (exit 127).
  local -a env_args=(
    -u SWIFT_DEBUG_INFORMATION_FORMAT
    -u SWIFT_DEBUG_INFORMATION_VERSION
    -u RUSTFLAGS
    -u CARGO_BUILD_RUSTFLAGS
    -u CARGO_ENCODED_RUSTFLAGS
    -u CARGO_BIN
    -u RUSTC
    -u IPHONEOS_DEPLOYMENT_TARGET
    -u TVOS_DEPLOYMENT_TARGET
    -u WATCHOS_DEPLOYMENT_TARGET
    -u XROS_DEPLOYMENT_TARGET
    -u DRIVERKIT_DEPLOYMENT_TARGET
  )
  local compiler_variable
  for compiler_variable in CC CC_aarch64_apple_darwin CC_x86_64_apple_darwin; do
    if [ -z "${!compiler_variable:-}" ]; then
      env_args+=(-u "$compiler_variable")
    fi
  done
  if [ -z "$pinned_channel" ]; then
    env_args+=(-u RUSTUP_TOOLCHAIN)
  fi
  # Defense-in-depth alongside assert_no_standalone_rust: force the rustup
  # proxy at the front of PATH for this invocation so any bare-name `rustc`
  # lookup inside the cargo subtree (sccache, build scripts, rustc-driven
  # tools) hits the proxy before /opt/homebrew/bin or /usr/local/bin. The
  # guard hard-fails on an installed standalone rust at those locations, but
  # a PATH that orders them ahead of ~/.cargo/bin remains a footgun for
  # anything cargo launches that does its own PATH resolution.
  if [ -d "$HOME/.cargo/bin" ]; then
    env_args+=("PATH=$HOME/.cargo/bin:${PATH:-}")
  fi
  if [ -n "$pinned_channel" ]; then
    env_args+=("RUSTUP_TOOLCHAIN=$pinned_channel")
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

daemon_build_features() {
  printf '%s\n' "harness-daemon/tokio-console"
}

daemon_rustflags_contract() {
  printf '%s\n' "config-plus-daemon-info-linker-args"
}

daemon_binary_output_path() {
  local target_dir profile_dir
  target_dir="$(resolve_cargo_target_dir)"
  profile_dir="$(daemon_build_profile_dir)"
  printf '%s/%s/harness-daemon\n' "$target_dir" "$profile_dir"
}

daemon_staged_binary_key() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local normalized_repo_root
  normalized_repo_root="$(cd "$repo_root" && pwd -P)"
  printf '%s' "$normalized_repo_root" | shasum -a 256 | awk '{ print substr($1, 1, 16) }'
}

daemon_staged_binary_path() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local target_dir profile_dir
  target_dir="$(resolve_cargo_target_dir)"
  profile_dir="$(daemon_build_profile_dir)"
  printf '%s/xcode-prebuilt/%s/%s/harness-daemon\n' \
    "$target_dir" \
    "$(daemon_staged_binary_key "$repo_root")" \
    "$profile_dir"
}

daemon_staged_binary_state_path() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  printf '%s.inputs\n' "$(daemon_staged_binary_path "$repo_root")"
}

daemon_staged_binary_sources_path() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  printf '%s.sources\n' "$(daemon_staged_binary_path "$repo_root")"
}

daemon_binary_dep_info_path() {
  local source_binary="${1:-$(daemon_binary_output_path)}"
  printf '%s.d\n' "$source_binary"
}

daemon_current_input_state() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local source_manifest="${2:-$(daemon_staged_binary_sources_path "$repo_root")}"
  local pinned_channel

  if [ ! -r "$source_manifest" ]; then
    printf 'daemon-cargo-build: staged compiler input manifest missing at %s\n' \
      "$source_manifest" >&2
    return 1
  fi

  pinned_channel="$(resolve_pinned_toolchain_channel "$repo_root")"
  /usr/bin/python3 "$DAEMON_INPUT_STATE_HELPER" state \
    --repo-root "$repo_root" \
    --source-manifest "$source_manifest" \
    --global-input "$repo_root/Cargo.toml" \
    --global-input "$repo_root/Cargo.lock" \
    --global-input "$repo_root/rust-toolchain.toml" \
    --global-input "$repo_root/.cargo" \
    --global-input "$repo_root/scripts/rustc-cache-wrapper.sh" \
    --global-input "$PROJECT_DIR/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist" \
    --global-input "${BASH_SOURCE[0]}" \
    --global-input "$(dirname -- "${BASH_SOURCE[0]}")/daemon-bundle-env.sh" \
    --metadata "profile=$(daemon_build_profile_dir)" \
    --metadata "features=$(daemon_build_features)" \
    --metadata "marketing_version=${MARKETING_VERSION:-}" \
    --metadata "toolchain=$pinned_channel" \
    --metadata "rustflags=$(daemon_rustflags_contract)" \
    --metadata "rustc_wrapper=${RUSTC_WRAPPER:-}" \
    --metadata "cargo_bin=${CARGO_BIN:-$HOME/.cargo/bin/cargo}" \
    --metadata "macosx_deployment_target=${MACOSX_DEPLOYMENT_TARGET:-}" \
    --metadata "cc=${CC:-}" \
    --metadata "cc_aarch64_apple_darwin=${CC_aarch64_apple_darwin:-}" \
    --metadata "cc_x86_64_apple_darwin=${CC_x86_64_apple_darwin:-}" \
    --metadata "developer_dir=${DEVELOPER_DIR:-}" \
    --metadata "sdkroot=${SDKROOT:-}"
}

daemon_build_invocation_token_path() {
  [ -n "${PROJECT_TEMP_DIR:-}" ] || return 1
  printf '%s/HarnessMonitor-daemon-build-invocation.id\n' "$PROJECT_TEMP_DIR"
}

daemon_staged_binary_ready_path() {
  [ -n "${PROJECT_TEMP_DIR:-}" ] || return 1
  printf '%s/HarnessMonitor-daemon-staged-ready.id\n' "$PROJECT_TEMP_DIR"
}

daemon_mark_staged_binary_ready() {
  local staged_binary="$1"
  local invocation_token_path ready_path ready_tmp

  [ -x "$staged_binary" ] || return 1
  invocation_token_path="$(daemon_build_invocation_token_path)" || return 0
  ready_path="$(daemon_staged_binary_ready_path)" || return 0
  [ -s "$invocation_token_path" ] || return 0
  ready_tmp="$ready_path.staging"
  (
    set -e
    trap '/bin/rm -f "$ready_tmp"' EXIT
    /bin/cp "$invocation_token_path" "$ready_tmp"
    /bin/mv -f "$ready_tmp" "$ready_path"
  )
}

daemon_staged_binary_is_ready_for_current_invocation() {
  local staged_binary="$1"
  local invocation_token_path ready_path

  [ -x "$staged_binary" ] || return 1
  [ -f "$staged_binary.inputs" ] || return 1
  [ -f "$staged_binary.sources" ] || return 1
  invocation_token_path="$(daemon_build_invocation_token_path)" || return 1
  ready_path="$(daemon_staged_binary_ready_path)" || return 1
  [ -s "$invocation_token_path" ] || return 1
  [ -s "$ready_path" ] || return 1
  /usr/bin/cmp -s "$invocation_token_path" "$ready_path"
}

daemon_staged_binary_is_fresh() {
  local staged_binary="$1"
  local repo_root="${2:-${repo_root:-$(resolve_repo_root)}}"
  local state_path source_manifest current_state

  [ -x "$staged_binary" ] || return 1
  state_path="$(daemon_staged_binary_state_path "$repo_root")"
  source_manifest="$(daemon_staged_binary_sources_path "$repo_root")"
  [ -f "$state_path" ] || return 1
  [ -f "$source_manifest" ] || return 1

  current_state="$(daemon_current_input_state "$repo_root" "$source_manifest")" || return 1
  [ "$(/bin/cat "$state_path")" = "$current_state" ]
}

stage_daemon_binary() {
  local source_binary="$1"
  local repo_root="${2:-${repo_root:-$(resolve_repo_root)}}"
  local staged_binary staged_dir staged_binary_tmp state_path state_tmp
  local source_manifest source_manifest_tmp dep_info_path current_state

  staged_binary="$(daemon_staged_binary_path "$repo_root")"
  staged_dir="$(dirname "$staged_binary")"
  staged_binary_tmp="$staged_binary.staging"
  state_path="$(daemon_staged_binary_state_path "$repo_root")"
  state_tmp="$state_path.staging"
  source_manifest="$(daemon_staged_binary_sources_path "$repo_root")"
  source_manifest_tmp="$source_manifest.staging"
  dep_info_path="${HARNESS_MONITOR_DAEMON_DEP_INFO_PATH:-$(daemon_binary_dep_info_path "$source_binary")}"

  /bin/mkdir -p "$staged_dir"
  if [ ! -r "$dep_info_path" ]; then
    printf 'daemon-cargo-build: compiler dep-info missing at %s\n' "$dep_info_path" >&2
    return 1
  fi
  /usr/bin/python3 "$DAEMON_INPUT_STATE_HELPER" manifest \
    --dep-info "$dep_info_path" \
    --repo-root "$repo_root" \
    --output "$source_manifest_tmp" || {
    /bin/rm -f "$source_manifest_tmp"
    return 1
  }
  if [ ! -s "$source_manifest_tmp" ]; then
    printf 'daemon-cargo-build: compiler dep-info contained no worktree inputs: %s\n' \
      "$dep_info_path" >&2
    /bin/rm -f "$source_manifest_tmp"
    return 1
  fi
  current_state="$(daemon_current_input_state "$repo_root" "$source_manifest_tmp")" || {
    /bin/rm -f "$source_manifest_tmp"
    return 1
  }
  (
    set -e
    trap '/bin/rm -f "$staged_binary_tmp" "$state_tmp" "$source_manifest_tmp"' EXIT
    /bin/cp -p "$source_binary" "$staged_binary_tmp"
    /bin/chmod 755 "$staged_binary_tmp"
    printf '%s\n' "$current_state" >"$state_tmp"
    /bin/mv -f "$staged_binary_tmp" "$staged_binary"
    /bin/mv -f "$source_manifest_tmp" "$source_manifest"
    /bin/mv -f "$state_tmp" "$state_path"
  ) || return 1

  printf '%s\n' "$staged_binary"
}

resolve_daemon_binary_for_bundle() {
  local repo_root="${1:-${repo_root:-$(resolve_repo_root)}}"
  local staged_binary built_binary

  staged_binary="$(daemon_staged_binary_path "$repo_root")"
  if daemon_staged_binary_is_ready_for_current_invocation "$staged_binary"; then
    printf '%s\n' "$staged_binary"
    return 0
  fi
  if daemon_staged_binary_is_fresh "$staged_binary" "$repo_root"; then
    printf '%s\n' "$staged_binary"
    return 0
  fi

  built_binary="$(build_daemon_binary | /usr/bin/tail -n 1)"
  stage_daemon_binary "$built_binary" "$repo_root" >/dev/null
  staged_binary="$(daemon_staged_binary_path "$repo_root")"
  daemon_mark_staged_binary_ready "$staged_binary"
  printf '%s\n' "$staged_binary"
}

build_daemon_binary() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local target_dir
  target_dir="$(resolve_cargo_target_dir)"

  local profile_dir
  profile_dir="$(daemon_build_profile_dir)"
  local features
  features="$(daemon_build_features)"
  local cargo_args=(
    rustc
    --package harness-daemon
    --bin harness-daemon
    --features "$features"
  )
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
