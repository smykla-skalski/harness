#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Each crate is checked on its own so its features resolve the way they will for
# whoever depends on it alone. One --workspace run cannot prove this: cargo
# unifies features across every selected package for the length of an
# invocation, so a crate that only builds because a sibling switched one of its
# optional dependencies on still passes. That is the whole point of the split,
# and it is why these stay twenty separate invocations.
#
# The caller wraps this in `cargo-local.sh --with-group-lease` so the twenty
# share one build lease instead of twenty, which is what stops them from
# sizing each other down to a fraction of the machine.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
cargo_local="$ROOT/scripts/cargo-local.sh"

"$cargo_local" check --all-targets -p harness-agents
"$cargo_local" check --all-targets -p harness-command
"$cargo_local" check --all-targets -p harness-daemon-client
"$cargo_local" check --all-targets -p harness-github-api
"$cargo_local" check --all-targets -p harness-infra
"$cargo_local" check --all-targets -p harness-kernel
"$cargo_local" check --all-targets -p harness-observe
"$cargo_local" check --all-targets -p harness-protocol
"$cargo_local" check --all-targets -p harness-run
"$cargo_local" check --all-targets -p harness-systemd-protocol
"$cargo_local" check --all-targets -p harness-task-board
"$cargo_local" check --all-targets -p harness-telemetry
"$cargo_local" check --all-targets -p harness-workspace
"$cargo_local" check -p harness --bin harness
"$cargo_local" check -p harness-hook --bin harness-hook
"$cargo_local" check -p harness-bridge --bin harness-bridge
"$cargo_local" check -p harness-mcp --bin harness-mcp
"$cargo_local" check -p harness-daemon --bin harness-daemon
"$cargo_local" check -p harness-panel --bin harness-panel
"$ROOT/scripts/run-linux-only.sh" "$cargo_local" check -p harness-systemd --bin harness-systemd
