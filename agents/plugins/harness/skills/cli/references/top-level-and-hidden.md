# CLI executable map

## Visible top-level commands

| Command | Purpose |
| --- | --- |
| `run` | Suite:run commands grouped by domain |
| `create` | Suite:create commands grouped by domain |
| `setup` | Setup environment and cluster commands |
| `observe` | Observe and classify harness-managed agent session logs |
| `session` | Multi-agent session orchestration |
| `task-board` | Cross-project task board |
| `daemon` | Control the local Harness daemon through `harness-daemon` |
| `bridge` | Control the host bridge through `harness-bridge` |

Sources: `harness --help`; `harness task-board --help`; `src/app/cli.rs`; `src/task_board/transport.rs`.

## Dedicated executables

| Executable | Purpose |
| --- | --- |
| `harness-hook` | Run lifecycle and suite hooks |
| `harness-daemon` | Run daemon services, including `serve` and `remote serve` |
| `harness-bridge` | Run the long-lived host bridge with `start` |
| `harness-mcp` | Run the Harness Monitor MCP server |

The v48 command surface is a hard cut: lifecycle, hook, MCP, and runtime entrypoints no longer run as hidden or nested `harness` commands.

Sources: `crates/harness-hook/src/main.rs`; `crates/harness-daemon/src/main.rs`; `crates/harness-bridge/src/main.rs`; `crates/harness-mcp/src/main.rs`.

## Global `--delay`

| Surface | Value |
| --- | --- |
| Flag | `--delay <DELAY>` |
| Scope | Global within each executable; inherited by its subcommands |
| Default | `0` |
| Meaning | Waits before executing the chosen command |
| Notes | Accepts fractional seconds such as `0.5`; prefer it over `sleep N && harness ...` |

Each executable applies its own `Cli.delay` once. When the root CLI delegates a control command, it removes the already-applied `--delay` from the worker argument vector.

Sources: `harness --help`; `crates/harness-command/src/lib.rs`; `src/app/cli.rs`; `crates/harness-daemon/src/main.rs`.
