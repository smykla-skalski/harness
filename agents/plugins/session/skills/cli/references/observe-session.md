# `observe` and `session` references

## `observe` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `observe scan [SESSION_ID]` | One-shot scan plus maintenance actions | Shared filters plus `--action`, `--issue-id`, `--since-line`, `--value`, `--range-a`, `--range-b`, `--codes` |
| `observe watch <SESSION_ID>` | Poll for new events continuously | `--poll-interval <POLL_INTERVAL>`, `--timeout <TIMEOUT>`, shared filters |
| `observe dump <SESSION_ID>` | Dump raw event history without classification | `--context-line`, `--context-window`, `--from-line`, `--to-line`, `--filter`, `--role`, `--tool-name`, `--raw-json`, `--project-hint` |
| `observe doctor` | Validate observe wiring, session pointers, and compact handoff state | `--json`, `--project-dir <PROJECT_DIR>` |

Top-level `harness observe` also accepts `--agent <AGENT>` (`claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`) and `--observe-id <OBSERVE_ID>`.

Sources: `cargo run --quiet -- observe --help`; `cargo run --quiet -- observe scan --help`; `cargo run --quiet -- observe watch --help`; `cargo run --quiet -- observe dump --help`; `cargo run --quiet -- observe doctor --help`; `src/app/cli.rs:139-145`; `src/observe/transport/args.rs:10-124`; `src/observe/transport/mode.rs:11-185`.

## Shared `observe` scan/watch filters

| Flag | Meaning |
| --- | --- |
| `--from-line <FROM_LINE>` / `--from <FROM>` | Start from a line number, timestamp, or prose match |
| `--focus <FOCUS>` | Focus preset: `harness`, `skills`, or `all` |
| `--project-hint <PROJECT_HINT>` | Narrow session resolution to one project directory name |
| `--json` / `--summary` | Switch output mode or append a summary |
| `--severity <SEVERITY>` | Minimum severity: `low`, `medium`, `critical` |
| `--category <CATEGORY>` / `--exclude <EXCLUDE>` | Include or exclude categories |
| `--fixable` / `--mute <MUTE>` | Restrict to fixable issues or mute issue codes |
| `--until-line`, `--since-timestamp`, `--until-timestamp` | Bound the scan window |
| `--format <FORMAT>` | Output `json` (default), `markdown`, or `sarif` |
| `--overrides <OVERRIDES>` / `--top-causes <TOP_CAUSES>` | Apply YAML overrides or show grouped root causes |
| `--output <OUTPUT>` / `--output-details <OUTPUT_DETAILS>` | Write truncated vs full issue output to files |

`observe scan --action` supports: `cycle`, `status`, `resume`, `verify`, `resolve-from`, `compare`, `list-categories`, `list-focus-presets`, `mute`, `unmute`.

Sources: `cargo run --quiet -- observe scan --help`; `cargo run --quiet -- observe watch --help`; `src/observe/transport/args.rs:10-70`; `src/observe/transport/mode.rs:14-43`; `src/observe/transport/mode.rs:173-185`.

## `session` command map

| Command | Purpose |
| --- | --- |
| `start` | Create a new multi-agent orchestration session |
| `join` | Register an agent into an existing session |
| `end` | End an active session |
| `assign` | Assign or change an agent role |
| `remove` | Remove an agent from a session |
| `transfer-leader` | Hand leader role to another agent |
| `task` | Work-item management family |
| `signal` | File-backed signal management family |
| `tui` | Managed interactive agent TUI family |
| `observe` | Observe all agents in one session |
| `sync` | Run one-shot liveness reconciliation |
| `leave` | Let one agent leave voluntarily |
| `title` | Set or update the session title |
| `status` | Show current session status |
| `list` | List sessions |

Nested families currently expose: `session task {create, assign, list, update, checkpoint}`, `session signal {send, list}`, and `session tui {start, attach, list, show, input, resize, stop}`.

Sources: `cargo run --quiet -- session --help`; `cargo run --quiet -- session task --help`; `cargo run --quiet -- session signal --help`; `cargo run --quiet -- session tui --help`; `src/session/transport/mod.rs:25-170`.

## `session start` reference

| Surface | Value |
| --- | --- |
| Required flag | `--context <CONTEXT>` |
| Optional flags | `--title <TITLE>`, `--project-dir <PROJECT_DIR>`, `--runtime <RUNTIME>`, `--session-id <SESSION_ID>` |
| Runtime values | `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode` |
| Runtime meaning | Leader runtime recorded when the session is created |
| Project-dir behavior | Defaults to cwd and also reads `CLAUDE_PROJECT_DIR` |
| Session-id behavior | Auto-generated if omitted |

Sources: `cargo run --quiet -- session start --help`; `src/session/transport/session_commands.rs:11-42`.

## Useful `session` follow-ons

| Command | Why it matters |
| --- | --- |
| `harness session observe <SESSION_ID>` | Read-only session-wide observe pass unless `--actor` is provided; `--poll-interval` turns it into watch mode and `--json` switches output format |
| `harness session sync <SESSION_ID>` | One-shot reconciliation for agent liveness; supports `--json` |
| `harness session status <SESSION_ID>` | Current session snapshot; supports `--json` |
| `harness session list` | Discover active sessions before joining or observing; `--all` includes archived sessions |

Sources: `cargo run --quiet -- session observe --help`; `cargo run --quiet -- session sync --help`; `cargo run --quiet -- session status --help`; `cargo run --quiet -- session list --help`; `src/session/transport/session_commands.rs:217-257`.
