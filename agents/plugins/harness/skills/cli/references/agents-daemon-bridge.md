# `harness-hook`, `harness-daemon`, and `harness-bridge` references

All commands below also accept the global `--delay <DELAY>` and `-h, --help` flags.

## `harness-hook` lifecycle map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `session-start` | Register or resume the active agent session for a project | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |
| `session-stop` | Clear the active agent session for a project | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |
| `prompt-submit` | Record a prompt-submission event in the shared agent ledger | `--agent <AGENT>`, `--project-dir <PROJECT_DIR>`, `--session-id <SESSION_ID>` |
| `pre-compact` | Save the compact handoff before compaction | `--project-dir <PROJECT_DIR>` |

`--agent` accepts: `claude`, `copilot`, `codex`, `gemini`, `vibe`, `opencode`.

`prompt-submit` reads the submitted payload from stdin before recording it.

Sources: `harness-hook --help`; `harness-hook session-start --help`; `harness-hook session-stop --help`; `harness-hook prompt-submit --help`; `crates/harness-hook/src/main.rs`; `src/agents/transport.rs`.

## Wrapper lifecycle command shapes

`src/setup/wrapper/registrations.rs` is the source of truth for how runtimes are wired into harness lifecycle commands.

| Lifecycle event | Command shape |
| --- | --- |
| Session start | `harness-hook session-start --agent <runtime> --project-dir <runtime-project-dir>` |
| Prompt submit | `harness-hook prompt-submit --agent <runtime> --project-dir <runtime-project-dir>` |
| Pre-compact | `harness-hook pre-compact --project-dir <runtime-project-dir>` |
| Session stop | `harness-hook session-stop --agent <runtime> --project-dir <runtime-project-dir>` |

Copilot, Codex, Vibe, and OpenCode use `"$PWD"` for `--project-dir`; Claude uses `"$CLAUDE_PROJECT_DIR"`; Gemini uses `"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}"`.

Sources: `src/setup/wrapper/registrations.rs:4-37`; `src/setup/wrapper/registrations.rs:52-75`; `src/setup/wrapper/registrations.rs:166-180`.

## Daemon command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `harness-daemon serve` | Serve the local daemon HTTP API | `--host <HOST>`, `--port <PORT>`, `--refresh-seconds <REFRESH_SECONDS>`, `--observe-seconds <OBSERVE_SECONDS>`, `--sandboxed`, `--codex-ws-url <URL>` |
| `harness-daemon dev` | Serve an unsandboxed dev daemon for the Harness Monitor app | `--host <HOST>`, `--port <PORT>`, `--app-group-id <APP_GROUP_ID>`, `--codex-ws-url <URL>` |
| `harness-daemon remote ...` | Serve and administer an internet-reachable daemon | `serve`, `pair`, `clients`, `acme`, `doctor`, and systemd lifecycle subcommands |
| `harness daemon status` | Show daemon manifest and project/session counts | no command-specific flags |
| `harness daemon stop` | Stop the local daemon | `--json` |
| `harness daemon restart` | Restart the local daemon | `--json` |
| `harness daemon install-launch-agent` | Install the per-user `LaunchAgent` plist | `--binary-path <BINARY_PATH>`, `--json` |
| `harness daemon remove-launch-agent` | Remove the per-user `LaunchAgent` plist | `--json` |
| `harness daemon doctor` | Run a local daemon diagnostics summary | no command-specific flags |
| `harness daemon snapshot` | Print one session snapshot for contract debugging | `--session <SESSION>`, `--json` |

`harness-daemon dev` is the unsandboxed wrapper over `harness-daemon serve`; its default app-group ID is `Q498EB36N4.io.harnessmonitor`. The root `harness daemon` surface is control-only; runtime routes (`serve`, `dev`, and `remote`) must invoke `harness-daemon` directly.

Sources: `harness-daemon --help`; `harness-daemon serve --help`; `harness-daemon dev --help`; `harness-daemon remote --help`; `harness daemon --help`; `crates/harness-daemon/src/main.rs`; `src/daemon/transport/commands.rs`.

## Bridge command map

| Command | Purpose | Key surface |
| --- | --- | --- |
| `harness-bridge start` | Start the unified host bridge | `--capability <CAPABILITIES>`, `--socket-path <PATH>`, `--codex-port <CODEX_PORT>`, `--codex-path <PATH>`, `--daemon` |
| `harness bridge stop` | Stop the running host bridge, if any | `--json` |
| `harness bridge status` | Print the current bridge status | `--plain` |
| `harness bridge reconfigure` | Reconfigure the running bridge without restarting it | `--enable <ENABLE>`, `--disable <DISABLE>`, `--force`, `--json` |
| `harness bridge install-launch-agent` | Install a per-user `LaunchAgent` that starts the bridge at login | `--capability <CAPABILITIES>`, `--socket-path <PATH>`, `--codex-port <CODEX_PORT>`, `--codex-path <PATH>` |
| `harness bridge remove-launch-agent` | Remove the bridge `LaunchAgent` and clean up persisted state | `--json` |

`--capability`, `--enable`, and `--disable` currently accept: `codex`, `agent-tui`, `acp`.

The root `harness bridge` surface is control-only; starting the long-lived runtime must invoke `harness-bridge start` directly.

Sources: `harness-bridge --help`; `harness-bridge start --help`; `harness bridge --help`; `crates/harness-bridge/src/main.rs`; `src/daemon/bridge/commands.rs`.
