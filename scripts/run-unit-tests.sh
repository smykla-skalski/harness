#!/usr/bin/env bash
set -euo pipefail

# Extra CLI arguments (e.g. -E 'test(=path::to::test)') arrive here as real
# positional parameters, so forwarding them via "$@" to every package group
# keeps each token's boundaries and quoting intact without re-parsing.
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness --lib --features full-runtime "$@"
./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-command -p harness-daemon-client -p harness-protocol -p harness-systemd-protocol -p harness-telemetry -p harness-testkit "$@"
./scripts/run-linux-only.sh ./scripts/cargo-local.sh nextest run --config-file .config/nextest.toml --user-config-file none -p harness-systemd "$@"
