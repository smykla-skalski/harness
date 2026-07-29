#!/usr/bin/env bash
set -euo pipefail

# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.
printf '==> test:unit 1/6: root Harness library\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$@"
printf '==> test:unit 2/6: supporting workspace crates\n' >&2
# harness-panel's build script otherwise shells out to npm to produce the
# assets it embeds; the unit-test gate exercises the Rust side only, so it
# gets the placeholder bundle instead of a frontend build on every run.
HARNESS_PANEL_SKIP_FRONTEND_BUILD=1 ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-daemon-root -p harness-daemon-state -p harness-db-schema -p harness-feature-flags -p harness-hooks -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-protocol -p harness-reviews -p harness-run -p harness-sybra -p harness-systemd-protocol -p harness-task-board -p harness-task-board-codex-requests -p harness-task-board-provider-sync -p harness-task-board-remote-viewer -p harness-telemetry -p harness-testkit -p harness-timeline -p harness-voice -p harness-workspace "$@"
# Own invocation: `acp` only compiles with `bridge-runtime`, which the rest of
# the supporting group above has no reason to build.
printf '==> test:unit 3/6: harness-agents (bridge-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"
# Extra invocation, on top of harness-task-board's own default-feature run
# above: `policy_runtime`'s tests live behind `daemon-runtime`, which the rest
# of the supporting group has no reason to build, so leaving it out of that
# group's features would drop policy_runtime's tests from this gate entirely.
printf '==> test:unit 4/6: harness-task-board (daemon-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$@"
printf '==> test:unit 5/6: Linux systemd crate\n' >&2
./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"
# Own invocation for the same reason as the group above: mixing this
# multi-target selection into a multi-package invocation would silently drop
# every other package's lib target instead of adding these. harness-daemon
# now owns and runs its own unit tests directly (`--lib`), no longer mirrored
# through root's own test build, alongside its always-separate bin tests.
printf '==> test:unit 6/6: harness-daemon (own lib and binary unit tests)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --lib --bin harness-daemon "$@"
