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
HARNESS_PANEL_SKIP_FRONTEND_BUILD=1 ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-protocol -p harness-reviews -p harness-run -p harness-systemd-protocol -p harness-telemetry -p harness-testkit -p harness-workspace "$@"
# Own invocation: `acp` only compiles with `bridge-runtime`, which the rest of
# the supporting group above has no reason to build.
printf '==> test:unit 3/6: harness-agents (bridge-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"
# Own invocation too: `policy_runtime`'s tests live behind `daemon-runtime`,
# which the rest of the supporting group above has no reason to build.
printf '==> test:unit 4/6: harness-task-board (daemon-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-task-board --lib --features daemon-runtime "$@"
printf '==> test:unit 5/6: Linux systemd crate\n' >&2
./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"
# --bin scopes cargo's target selection to the harness-daemon binary only, so
# this stays separate from the group above: mixing it into a multi-package
# invocation would silently drop every other package's lib target instead of
# adding this one. The lib keeps test = false to skip the #[path]-shared
# content it pulls from the root crate; the bin has no such content, so its
# own #[cfg(test)] tests are safe to run here.
printf '==> test:unit 6/6: harness-daemon binary-only unit tests\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-daemon --bin harness-daemon "$@"
