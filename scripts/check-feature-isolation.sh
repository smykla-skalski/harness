#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Each crate is checked on its own so its features resolve the way they will for
# whoever depends on it alone. One --workspace run cannot prove this: cargo
# unifies features across every selected package for the length of an
# invocation, so a crate that only builds because a sibling switched one of its
# optional dependencies on still passes. That is the whole point of the split,
# and it is why these stay eleven invocations.
#
# The caller wraps this in `cargo-local.sh --with-group-lease` so the eleven
# share one build lease instead of eleven, which is what stops them from sizing
# each other down to a fraction of the machine.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
cargo_local="$ROOT/scripts/cargo-local.sh"

"$cargo_local" check --all-targets -p harness-command
"$cargo_local" check --all-targets -p harness-daemon-client
"$cargo_local" check --all-targets -p harness-protocol
"$cargo_local" check --all-targets -p harness-systemd-protocol
"$cargo_local" check --all-targets -p harness-telemetry
"$cargo_local" check -p harness --bin harness
"$cargo_local" check -p harness-hook --bin harness-hook
"$cargo_local" check -p harness-bridge --bin harness-bridge
"$cargo_local" check -p harness-mcp --bin harness-mcp
"$cargo_local" check -p harness-daemon --bin harness-daemon
"$ROOT/scripts/run-linux-only.sh" "$cargo_local" check -p harness-systemd --bin harness-systemd
