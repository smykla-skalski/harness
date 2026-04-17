# Top-level and hidden commands

## Visible top-level commands

| Command | Purpose |
| --- | --- |
| `hook` | Run a harness hook for a skill |
| `run` | Suite:run commands grouped by domain |
| `create` | Suite:create commands grouped by domain |
| `setup` | Setup environment and cluster commands |
| `agents` | Shared harness-managed agent lifecycle commands |
| `observe` | Observe and classify harness-managed agent session logs |
| `session` | Multi-agent session orchestration |
| `daemon` | Local daemon for the Harness app |
| `bridge` | Supervise host capabilities for sandboxed Codex and agent TUI flows |

Sources: `cargo run --quiet -- --help`; `src/app/cli.rs:96-158`.

## Hidden top-level commands

| Command | Purpose | Source note |
| --- | --- | --- |
| `session-start` | Handle session start hook | Hidden with `#[command(hide = true)]` |
| `session-stop` | Handle session stop cleanup | Hidden with `#[command(hide = true)]` |
| `pre-compact` | Save compact handoff before compaction | Hidden with `#[command(hide = true)]` |

Sources: `src/app/cli.rs:127-137`.

## Global `--delay`

| Surface | Value |
| --- | --- |
| Flag | `--delay <DELAY>` |
| Scope | Global; inherited by top-level commands and subcommands |
| Default | `0` |
| Meaning | Waits before executing the chosen command |
| Notes | Accepts fractional seconds such as `0.5`; prefer it over `sleep N && harness ...` |

Implementation: `Cli.delay` is declared with `#[arg(long, default_value = "0", global = true)]`, and `run()` sleeps with `thread::sleep(Duration::from_secs_f64(cli.delay))` when the value is greater than zero.

Sources: `cargo run --quiet -- --help`; `src/app/cli.rs:29-39`; `src/app/cli.rs:236-240`.
