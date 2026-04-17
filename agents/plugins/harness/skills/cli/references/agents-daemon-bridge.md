# `agents`, `daemon`, and `bridge` references

All commands below also accept the global `--delay <DELAY>` and `-h, --help` flags.

## `agents` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `agents session-start` | Register or resume the active agent session for a project | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |
| `agents session-stop` | Clear the active agent session for a project | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |
| `agents prompt-submit` | Record a prompt-submission event in the shared agent ledger | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |

`--agent` accepts: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`.

`prompt-submit` reads the submitted payload from stdin before recording it.

Sources: `cargo run --quiet -- agents --help`; `cargo run --quiet -- agents session-start --help`; `cargo run --quiet -- agents session-stop --help`; `cargo run --quiet -- agents prompt-submit --help`; `src/agents/transport.rs:12-114`.

## Wrapper lifecycle command shapes

`src/setup/wrapper/registrations.rs` is the source of truth for how runtimes are wired into harness lifecycle commands.

| Lifecycle event | Command shape |
| --- | --- |
| Session start | `harness agents session-start --agent <runtime> --project-dir <runtime-project-dir>` |
| Prompt submit | `harness agents prompt-submit --agent <runtime> --project-dir <runtime-project-dir>` |
| Pre-compact | `harness pre-compact --project-dir <runtime-project-dir>` |
| Session stop | `harness agents session-stop --agent <runtime> --project-dir <runtime-project-dir>` |

Copilot, Codex, Vibe, and OpenCode use `"$PWD"` for `--project-dir`; Claude uses `"$CLAUDE_PROJECT_DIR"`; Gemini uses `"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}"`.

Sources: `src/setup/wrapper/registrations.rs:4-37`; `src/setup/wrapper/registrations.rs:52-75`; `src/setup/wrapper/registrations.rs:166-180`.

## `daemon` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `daemon serve` | Serve the local daemon HTTP API | `--host <HOST>`, `--port <PORT>`, `--refresh-seconds <REFRESH_SECONDS>`, `--observe-seconds <OBSERVE_SECONDS>`, `--sandboxed`, `--codex-ws-url <URL>` |
| `daemon dev` | Serve an unsandboxed dev daemon for the Harness Monitor app | `--host <HOST>`, `--port <PORT>`, `--app-group-id <APP_GROUP_ID>`, `--codex-ws-url <URL>` |
| `daemon status` | Show daemon manifest and project/session counts | no command-specific flags |
| `daemon stop` | Stop the local daemon | `--json` |
| `daemon restart` | Restart the local daemon | `--json` |
| `daemon install-launch-agent` | Install the per-user `LaunchAgent` plist | `--binary-path <BINARY_PATH>`, `--json` |
| `daemon remove-launch-agent` | Remove the per-user `LaunchAgent` plist | `--json` |
| `daemon doctor` | Run a local daemon diagnostics summary | no command-specific flags |
| `daemon snapshot` | Print one session snapshot for contract debugging | `--session <SESSION>`, `--json` |

`daemon dev` is the unsandboxed wrapper over `daemon serve`; its default app-group ID is `Q498EB36N4.io.harnessmonitor`.

Sources: `cargo run --quiet -- daemon --help`; `cargo run --quiet -- daemon serve --help`; `cargo run --quiet -- daemon dev --help`; `cargo run --quiet -- daemon status --help`; `cargo run --quiet -- daemon stop --help`; `cargo run --quiet -- daemon restart --help`; `cargo run --quiet -- daemon install-launch-agent --help`; `cargo run --quiet -- daemon remove-launch-agent --help`; `cargo run --quiet -- daemon doctor --help`; `cargo run --quiet -- daemon snapshot --help`; `src/daemon/transport/commands.rs:22-45`; `src/daemon/transport/commands.rs:112-191`.

## `bridge` command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `bridge start` | Start the unified host bridge | `--capability <CAPABILITIES>`, `--socket-path <PATH>`, `--codex-port <CODEX_PORT>`, `--codex-path <PATH>`, `--daemon` |
| `bridge stop` | Stop the running host bridge, if any | `--json` |
| `bridge status` | Print the current bridge status | `--plain` |
| `bridge reconfigure` | Reconfigure the running bridge without restarting it | `--enable <ENABLE>`, `--disable <DISABLE>`, `--force`, `--json` |
| `bridge install-launch-agent` | Install a per-user `LaunchAgent` that starts the bridge at login | `--capability <CAPABILITIES>`, `--socket-path <PATH>`, `--codex-port <CODEX_PORT>`, `--codex-path <PATH>` |
| `bridge remove-launch-agent` | Remove the bridge `LaunchAgent` and clean up persisted state | `--json` |

`--capability`, `--enable`, and `--disable` currently accept: `codex`, `agent-tui`.

Sources: `cargo run --quiet -- bridge --help`; `cargo run --quiet -- bridge start --help`; `cargo run --quiet -- bridge stop --help`; `cargo run --quiet -- bridge status --help`; `cargo run --quiet -- bridge reconfigure --help`; `cargo run --quiet -- bridge install-launch-agent --help`; `cargo run --quiet -- bridge remove-launch-agent --help`; `src/daemon/bridge/commands.rs:29-44`; `src/daemon/bridge/commands.rs:95-233`.
