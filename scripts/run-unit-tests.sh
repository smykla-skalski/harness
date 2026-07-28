#!/usr/bin/env bash
set -euo pipefail

# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.
printf '==> test:unit 1/4: root Harness library\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$@"
printf '==> test:unit 2/4: supporting workspace crates\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-infra -p harness-kernel -p harness-mcp -p harness-observe -p harness-panel -p harness-protocol -p harness-run -p harness-systemd-protocol -p harness-task-board -p harness-telemetry -p harness-testkit -p harness-workspace "$@"
# Own invocation: `acp` only compiles with `bridge-runtime`, which the rest of
# the supporting group above has no reason to build.
printf '==> test:unit 3/4: harness-agents (bridge-runtime feature)\n' >&2
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-agents --lib --features bridge-runtime "$@"
printf '==> test:unit 4/4: Linux systemd crate\n' >&2
./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"
