#!/usr/bin/env bash
set -euo pipefail

# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.
printf '==> test:unit 1/7: root Harness library\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$@"
printf '==> test:unit 2/7: supporting workspace crates\n' >&2
# harness-panel's build script otherwise shells out to npm to produce the
# assets it embeds; the unit-test gate exercises the Rust side only, so it
# gets the placeholder bundle instead of a frontend build on every run.
HARNESS_PANEL_SKIP_FRONTEND_BUILD=1 ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-acme-dns -p harness-command -p harness-daemon-acp-probe -p harness-daemon-cli -p harness-daemon-client -p harness-daemon-discovery -p harness-daemon-launchd -p harness-daemon-provider-credentials -p harness-daemon-root -p harness-daemon-snapshot -p harness-daemon-state -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-policy-graph-store -p harness-protocol -p harness-remote-trust -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace "$@"
# Own invocation: `acp` only compiles with `bridge-runtime`, which the rest of
# the supporting group above has no reason to build.
printf '==> test:unit 3/7: harness-agents (bridge-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"
# Extra invocation, on top of harness-task-board's own default-feature run
# above: `policy_runtime`'s tests live behind `daemon-runtime`, which the rest
# of the supporting group has no reason to build, so leaving it out of that
# group's features would drop policy_runtime's tests from this gate entirely.
printf '==> test:unit 4/7: harness-task-board (daemon-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$@"
printf '==> test:unit 5/7: Linux systemd crate\n' >&2
./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"
# Own invocation for the same reason as the group above: mixing this
# multi-target selection into a multi-package invocation would silently drop
# every other package's lib target instead of adding these. harness-daemon
# now owns and runs its own unit tests directly (`--lib`), no longer mirrored
# through root's own test build.
printf '==> test:unit 6/7: harness-daemon (own lib)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib "$@"
# Separate invocation, not folded into the group above: nextest's target-type
# flags (`--lib` here) apply to every `-p` package in one invocation, not just
# the one they're written next to. harness-daemon-bin has no lib target at
# all - its `[[bin]]` moved here from harness-daemon (#1230) - so combining it
# with harness-daemon's `--lib` run above would silently drop its own unit
# tests and its systemd-compat integration test, which spawns the compiled
# binary and needs no target-type restriction to be found.
printf '==> test:unit 7/7: harness-daemon-bin (binary unit and integration tests)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon-bin "$@"
