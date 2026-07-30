#!/usr/bin/env bash
set -euo pipefail
unalias -a 2>/dev/null || true

# Each crate is checked on its own so its features resolve the way they will for
# whoever depends on it alone. One --workspace run cannot prove this: cargo
# unifies features across every selected package for the length of an
# invocation, so a crate that only builds because a sibling switched one of its
# optional dependencies on still passes. That is the whole point of the split,
# and it is why these stay separate invocations.
#
# The caller wraps this in `cargo-local.sh --with-group-lease` so they share one
# build lease, which stops them from sizing each other down to a fraction of
# the machine.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
cargo_local="$ROOT/scripts/cargo-local.sh"

"$cargo_local" check --all-targets -p harness-agents
"$cargo_local" check --all-targets -p harness-command
"$cargo_local" check --all-targets -p harness-daemon-cli
"$cargo_local" check --all-targets -p harness-daemon-client
"$cargo_local" check --all-targets -p harness-daemon-discovery
"$cargo_local" check --all-targets -p harness-daemon-launchd
"$cargo_local" check --all-targets -p harness-daemon-codex
"$cargo_local" check --all-targets -p harness-daemon-remote-cli
"$cargo_local" check --all-targets -p harness-daemon-root
"$cargo_local" check --all-targets -p harness-daemon-state
"$cargo_local" check --all-targets -p harness-daemon-watch
"$cargo_local" check --all-targets -p harness-github-api
"$cargo_local" check --all-targets -p harness-hooks
"$cargo_local" check --all-targets -p harness-infra
"$cargo_local" check --all-targets -p harness-kernel
"$cargo_local" check --all-targets -p harness-observe
"$cargo_local" check --all-targets -p harness-protocol
"$cargo_local" check --all-targets -p harness-remote-trust
"$cargo_local" check --all-targets -p harness-run
"$cargo_local" check --all-targets -p harness-session
"$cargo_local" check --all-targets -p harness-systemd-protocol
"$cargo_local" check --all-targets -p harness-task-board
"$cargo_local" check --all-targets -p harness-task-board-git-runtime
"$cargo_local" check --all-targets -p harness-telemetry
"$cargo_local" check --all-targets -p harness-workspace
"$cargo_local" check -p harness --bin harness
"$cargo_local" check -p harness-hook --bin harness-hook
"$cargo_local" check -p harness-bridge --bin harness-bridge
# harness-bridge declares `daemon-runtime` alongside its default
# `bridge-runtime`; checked here, `--all-targets` and all, so a future
# `crate::daemon` change that only compiles under one of the two goes
# unnoticed the same way #1159 did.
"$cargo_local" check --all-targets -p harness-bridge --features daemon-runtime
"$cargo_local" check -p harness-mcp --bin harness-mcp
"$cargo_local" check -p harness-daemon-bin --bin harness-daemon
"$cargo_local" check -p harness-panel --bin harness-panel
"$ROOT/scripts/run-linux-only.sh" "$cargo_local" check -p harness-systemd --bin harness-systemd
