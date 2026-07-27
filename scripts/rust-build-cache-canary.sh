#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/rust-build-cache-canary.XXXXXX")"
PROJECT_A="$SANDBOX/projects/a"
PROJECT_B="$SANDBOX/projects/b"
TARGET_A="$SANDBOX/target/dev/wt-canary-a"
TARGET_B="$SANDBOX/target/dev/wt-canary-b"
CARGO_HOME_CANARY="$SANDBOX/cargo-home"
CARGO_BIN="${HARNESS_CARGO_BIN:-cargo}"

if ! awk '
  /^\[/ { in_unstable = ($0 == "[unstable]"); next }
  in_unstable && /^[[:space:]]*checksum-freshness[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
    found = 1
  }
  END { exit(found ? 0 : 1) }
' "$ROOT/.cargo/config.toml"; then
  printf 'error: .cargo/config.toml does not enable checksum freshness\n' >&2
  exit 1
fi

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

mkdir -p "$PROJECT_A/src" "$CARGO_HOME_CANARY"
cat >"$PROJECT_A/Cargo.toml" <<'EOF'
[package]
name = "harness_cache_canary"
version = "0.1.0"
edition = "2024"
build = "build.rs"

[workspace]
EOF
cat >"$PROJECT_A/build.rs" <<'EOF'
use std::{env, fs, path::PathBuf};

fn main() {
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    fs::write(
        out_dir.join("generated.rs"),
        "pub const GENERATED: u8 = 42;\n",
    )
    .expect("write generated source");
    println!("cargo:rerun-if-changed=build-input.txt");
}
EOF
printf 'canary input\n' >"$PROJECT_A/build-input.txt"
cat >"$PROJECT_A/src/lib.rs" <<'EOF'
include!(concat!(env!("OUT_DIR"), "/generated.rs"));

pub fn canary() -> u8 {
    GENERATED
}
EOF
/bin/cp -pR "$PROJECT_A" "$PROJECT_B"
# Git creates each worktree at a different time. Make that difference explicit
# so the canary proves checksum freshness, not an accidentally preserved mtime.
touch "$PROJECT_B/Cargo.toml" "$PROJECT_B/src/lib.rs"

run_cargo() {
  local project="$1" target="$2" log_path="$3"
  (
    unset CARGO_BUILD_BUILD_DIR CARGO_ENCODED_RUSTFLAGS RUSTC_WRAPPER
    export CARGO_HOME="$CARGO_HOME_CANARY"
    export CARGO_INCREMENTAL=1
    export CARGO_NET_OFFLINE=true
    export CARGO_TARGET_DIR="$target"
    export CARGO_TERM_COLOR=never
    export CARGO_UNSTABLE_CHECKSUM_FRESHNESS=true
    cd "$project"
    "$CARGO_BIN" build --manifest-path Cargo.toml --verbose
  ) 2>&1 | tee "$log_path"
}

printf '==> cache canary: compiling the donor lane\n' >&2
run_cargo "$PROJECT_A" "$TARGET_A" "$SANDBOX/first-build.log"
if ! grep -Fq "Compiling harness_cache_canary" "$SANDBOX/first-build.log"; then
  printf 'error: the donor build did not compile the canary crate\n' >&2
  exit 1
fi

printf '==> cache canary: cloning the donor into a fresh checkout lane\n' >&2
set +e
python3 "$ROOT/scripts/seed-rust-build-lane.py" \
  --repo-root "$SANDBOX" \
  --target-dir "$TARGET_B" \
  --target-segment wt-canary-b \
  --require-seed &
first_seed_pid=$!
python3 "$ROOT/scripts/seed-rust-build-lane.py" \
  --repo-root "$SANDBOX" \
  --target-dir "$TARGET_B" \
  --target-segment wt-canary-b \
  --require-seed &
second_seed_pid=$!
wait "$first_seed_pid"
first_seed_status=$?
wait "$second_seed_pid"
second_seed_status=$?
set -e
if (( first_seed_status == 3 && second_seed_status == 3 )); then
  printf 'ok: Rust build-lane cache canary skipped; filesystem has no copy-on-write clone support\n'
  exit 0
fi
if (( first_seed_status != 0 || second_seed_status != 0 )); then
  printf 'error: concurrent lane seed statuses were %d and %d\n' \
    "$first_seed_status" "$second_seed_status" >&2
  exit 1
fi

printf '==> cache canary: building the identical crate from a second checkout\n' >&2
run_cargo "$PROJECT_B" "$TARGET_B" "$SANDBOX/second-build.log"
if ! grep -Fq "Fresh harness_cache_canary" "$SANDBOX/second-build.log"; then
  printf 'error: Cargo did not reuse the cloned canary artifact\n' >&2
  exit 1
fi
if grep -Fq "Compiling harness_cache_canary" "$SANDBOX/second-build.log"; then
  printf 'error: Cargo recompiled the canary after lane seeding\n' >&2
  exit 1
fi

printf '==> cache canary: rebuilding a branch-local change without the donor\n' >&2
rm -rf "$TARGET_A"
cat >>"$PROJECT_B/src/lib.rs" <<'EOF'

pub fn branch_change() -> u8 {
    GENERATED + 1
}
EOF
run_cargo "$PROJECT_B" "$TARGET_B" "$SANDBOX/branch-build.log"
if ! grep -Fq "Compiling harness_cache_canary" "$SANDBOX/branch-build.log"; then
  printf 'error: Cargo did not rebuild the changed branch-local crate\n' >&2
  exit 1
fi

printf 'ok: a fresh checkout reused Cargo artifacts from an isolated COW build lane\n'
