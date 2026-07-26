# `setup` references

## `setup` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `setup bootstrap` | Install or refresh the repo-aware harness wrapper and write agent bootstrap config | `--project-dir <PROJECT_DIR>`, `--agents <AGENTS>...`, `--skip-runtime-hooks <AGENTS>...` |
| `setup capabilities` | Emit a structured capabilities/readiness report for planning | `--project-dir`, `--repo-root` |

Sources: `cargo run --quiet -- setup --help`; `src/app/cli.rs`; `src/setup/bootstrap.rs`; `src/setup/capabilities.rs`.

## `setup` key help surface

| Command | Flags / arguments | Notes |
| --- | --- | --- |
| `harness setup bootstrap` | `--project-dir <PROJECT_DIR>`, `--agents <AGENTS>...`, `--skip-runtime-hooks <AGENTS>...` | `--agents` defaults to all supported agents; `--skip-runtime-hooks` leaves the rest of bootstrap intact while suppressing runtime hook configs for the listed runtimes |
| `harness setup capabilities` | `--project-dir`, `--repo-root` | Prints JSON |

Sources: `cargo run --quiet -- setup bootstrap --help`; `cargo run --quiet -- setup capabilities --help`; `src/setup/bootstrap.rs`; `src/setup/capabilities.rs`.

## Canonical `setup` shortcuts

| Use case | Command |
| --- | --- |
| Copilot bootstrap path | `harness setup bootstrap --agents copilot` |
| Bootstrap without Gemini/Copilot runtime hooks | `harness setup bootstrap --skip-runtime-hooks gemini,copilot` |

Sources: `cargo run --quiet -- setup bootstrap --help`.
