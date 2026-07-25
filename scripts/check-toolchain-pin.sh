#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Three files name the Rust toolchain and cargo fingerprints rustc into every
# artifact it builds. A bump that lands in one file leaves every cargo run that
# resolves a different file compiling against a different rustc, which discards
# the whole shared target tree the moment it runs. Renovate has done exactly
# this twice, touching only rust-toolchain.toml.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"

read_quoted_value() {
  awk -F'"' -v key="$2" '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {print $2; exit}' "$1"
}

toolchain_pin="$(read_quoted_value "$ROOT/rust-toolchain.toml" channel)"
mise_pin="$(read_quoted_value "$ROOT/.mise.toml" rust)"
lock_pin="$(awk '/^\[\[tools\.rust\]\]/ {found = 1; next}
                 found && /^version[[:space:]]*=/ {gsub(/"/, "", $3); print $3; exit}' \
  "$ROOT/mise.lock")"

errors=()
[ -n "$toolchain_pin" ] || errors+=("rust-toolchain.toml declares no channel")
[ "$toolchain_pin" = "$mise_pin" ] \
  || errors+=(".mise.toml rust=$mise_pin != rust-toolchain.toml channel=$toolchain_pin")
[ "$toolchain_pin" = "$lock_pin" ] \
  || errors+=("mise.lock tools.rust=$lock_pin != rust-toolchain.toml channel=$toolchain_pin")

# A pin nothing has installed is the same cold rebuild by another route: rustup
# resolves it, downloads a second toolchain, and every fingerprint changes.
if active="$(cd "$ROOT" && rustup show active-toolchain 2>/dev/null)"; then
  active="${active%% *}"
  case "$active" in
    "$toolchain_pin" | "$toolchain_pin"-*) ;;
    "") errors+=("rustup reported no active toolchain") ;;
    *) errors+=("active toolchain $active != pinned $toolchain_pin (run: rustup toolchain install $toolchain_pin)") ;;
  esac
else
  # Skipping this quietly would let the environment this gate exists to catch
  # pass it, since a host with no working rustup is exactly one that resolves
  # some other toolchain and rebuilds cold.
  errors+=("rustup could not report an active toolchain, so the pin cannot be proven live")
fi

# The Linux profile links with mold. A host without it fails deep in the link
# step with an unknown-linker error from cc, which names neither the flag nor
# where it came from.
if [[ "$(uname -s)" == "Linux" ]] \
  && grep -q 'fuse-ld=mold' "$ROOT/.cargo/config.toml"; then
  if ! command -v mold >/dev/null 2>&1 && ! command -v ld.mold >/dev/null 2>&1; then
    errors+=("mold is the configured Linux linker but is not on PATH (install it, for example: apt install mold)")
  fi
fi

if ((${#errors[@]})); then
  printf 'toolchain pin drift:\n' >&2
  printf '  - %s\n' "${errors[@]}" >&2
  exit 1
fi

printf 'toolchain: pin %s agrees across rust-toolchain.toml, .mise.toml, and mise.lock, and the configured linker is present\n' \
  "$toolchain_pin"
