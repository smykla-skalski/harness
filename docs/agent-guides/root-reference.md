# Root Agent Reference

Load this file only when the repo-root `AGENTS.md` routes the current task here. The root `AGENTS.md` contains the mandatory contract; this file keeps the longer reference material out of the default prompt path.

## Hook system

Hooks intercept agent tool usage. The hook commands are defined in `crates/harness-hook/src/main.rs`:

- Unified tool lifecycle: `tool-guard` and `tool-result`, plus the `audit-turn` shim.

The suite-lifecycle hooks (`guard-stop`, `context-agent`, `validate-agent`, `tool-failure`) and the `HARNESS_FEATURE_SUITE_HOOKS` flag that gated them have been removed; only the tool lifecycle remains.

Repo-policy/manual-task enforcement belongs to `aff`. Use harness setup tasks for harness-owned outputs and the separate `aff:*` tasks for aff-owned runtime hooks.

## Key modules

Paths are relative to the repository root.

- `crates/harness-kernel/` - unified error and hook-message system, XDG paths, build info, and skill constants.
- `src/app/cli.rs` - the top-level command tree and its dispatch.
- `src/hooks/` - tool lifecycle hook handlers, guards, and hook protocol types.
- `src/workspace/compact/` - file fingerprinting with SHA256 and mtime.
- `src/session/` - multi-agent orchestration types, roles, storage, service, transport, and observation.
- `src/task_board/` - cross-project board state, planning gates, dispatch/evaluate reconciliation, orchestrator state, external sync, and policy pipeline graph evaluation. See `docs/agent-guides/task-board-workflow.md` for operator behavior.
- `src/agents/runtime/` - runtime adapters, conversation events, signal protocol, and liveness detection.

## Facade-crate src includes

Several `src/` files compile into more than one crate. `crates/harness-daemon`, `crates/harness-bridge`, `crates/harness-hook`, `crates/harness-mcp`, `crates/harness-protocol`, and `crates/harness-telemetry` each pull selected root-crate sources in with `#[path = "../../../src/..."]` (some deeper), so those files compile once per crate that includes them, and every copy resolves `crate::` against that crate's own module tree rather than the root crate's.

Find every crate that pulls in a given file with `grep -rFn "src/<file>" crates/`, replacing `<file>` with the file's path under `src/` (for example `workspace/adopter.rs`); `-F` matches the substring literally, so a filename's own dots never widen the match. A file reached only through an included `mod.rs` - for example anything under `src/agents/acp/`, reached via `src/agents/acp/mod.rs` - does not show up on a direct grep for itself, so also check whether an ancestor module is included.

Because each include resolves against a different module tree, a change that compiles cleanly in the root crate can still fail, or expose a different symbol set, inside a facade crate that a package-scoped gate never builds. `mise run harness:check:rust` (part of `mise run check`) runs Clippy on every crate in the list above and is the run that predicts whether the repository check passes; `cargo clippy -p <owning-crate>` alone does not.

## Managed ACP agents

Harness speaks the Agent Client Protocol (ACP, wire protocol v1) to agents it manages for a session. The client half lives in `src/agents/acp/` (connection, streaming events, permission bridge, supervision); the daemon half in `src/daemon/agent_acp/` (protocol loop, session lifecycle, per-agent state, and the HTTP routes the CLI and Monitor call). Wire types shared with the Monitor live in `crates/harness-protocol/src/managed_agents/acp/`.

Bundled adapters are version-pinned by harness: `codex-acp` (`crates/harness-codex-acp/`) and the OpenRouter agent (`crates/harness-openrouter-agent/`). External adapters such as `claude-agent-acp` and `copilot --acp` are user-installed; harness does not pin them and surfaces their reported version through inspect instead of managing it.

### Handshake and capabilities

On `session/initialize` harness advertises fixed client capabilities (`fs.readTextFile`/`writeTextFile`, terminal, and boolean session config options) and records the agent's response as an `AcpAgentHandshake`: the negotiated protocol version, agentInfo (name, version, title), auth methods, and one flag per stable-v1 capability (load, list, resume, close, and delete session, additionalDirectories, MCP http/sse, and logout). Every lifecycle call is gated on the matching capability and falls back cleanly when the agent does not advertise it.

### Session lifecycle

`session/new` carries `additionalDirectories` and `mcpServers`, both defaulting to empty; MCP http/sse entries are dropped for agents that do not advertise the transport. When a pooled agent process dies, harness prefers `session/resume` on the fresh process, then `session/load` with replay-safe persistence, then a new session. `session/close` fires on teardown for agents that support it. The ids `session/list` reports belong to the agent, so harness treats them as display data distinct from its own session ids.

### Telemetry

Prompt-turn usage, message ids, and stop reasons (refusal included) flow into `ConversationEvent` payloads without changing the event's own wire shape, so the Monitor decodes them without codegen churn. The `config_option_update`, `current_mode_update`, `available_commands_update`, and `session_info_update` notifications mutate the per-session `AcpAgentSessionState` surfaced through inspect.

### Remote transport

A start can replace the descriptor's command with a remote endpoint: `--endpoint` with a `ws`/`wss` URL connects over WebSocket, an `http`/`https` URL over SSE with POST. `--header-env Name=ENV_VAR` resolves each header value from the daemon's environment at connect time, so no secret rides the request; WebSocket connects drop request headers, so `--header-env` needs an http/https endpoint. Remote agents run the same protocol loop behind a childless supervisor with no pid or stderr tail. The transport lives behind `agent-client-protocol-http`, gated on the `daemon-runtime` feature.

### CLI

`harness session agents start acp` launches a descriptor or, with `--endpoint`, connects to a remote one. `harness session agents acp` groups the live-agent verbs: `inspect` (a per-agent doctor view of protocol version, agentInfo, and freshness notes, or `--json` for the raw daemon snapshot), `logout`, `sessions`, `close-session`, and `delete-session`. See `docs/agent-guides/task-board-workflow.md` for the operator summary.

## Data directories

- `$XDG_DATA_HOME/harness/sessions/` - session workspaces.
- `$XDG_DATA_HOME/harness/contexts/{session-hash}/` - session context.
- `$XDG_DATA_HOME/harness/projects/project-{digest}/orchestration/` - multi-agent session state.
- `$XDG_DATA_HOME/harness/projects/project-{digest}/agents/signals/` - file-based agent signaling.
- Task-board state uses the board root resolved by the CLI/daemon, normally under the project Harness data area. Access it through `harness task-board` commands or daemon task-board routes instead of reading JSON files directly.

## Testing details

Integration tests live in `tests/integration/` and cover hooks, commands, and workflows end to end. Canonical Rust test tasks use nextest process isolation and parallel scheduling. A test must isolate its environment, filesystem paths, ports, and external resource names instead of requiring runner-wide serialization. Tests that read XDG paths must isolate state with `temp_env::with_vars`, setting both `XDG_DATA_HOME` and `CLAUDE_SESSION_ID`. Avoid mocks; tests use real filesystem state.

That one directory feeds two test targets, which differ in the library they can link rather than in how many tests they hold. `tests/integration.rs` declares the modules that compile without `full-runtime`, and `tests/integration_daemon.rs` declares the ones that reach symbols gated behind it - daemon, bridge, ACP and MCP. Only the second carries `required-features`, so a run that leaves the feature off skips it and links `integration` against a library without axum, sqlx, hyper and rustls, while the full gate enables the feature and builds both. Editing a test rebuilds one target instead of both either way.

Declare a new module in whichever root matches what it imports, and move a module between targets by moving its `mod` line rather than its file. A module that needs `full-runtime` but is declared in `tests/integration.rs` fails to compile with an unresolved daemon path, which is the intended signal. `tests/integration/helpers/` is shared by both roots and must stay free of gated symbols; because each target uses only part of it, the module allows dead code and unused re-exports on purpose.

## Rust build concurrency

`scripts/cargo-local.sh` sizes `CARGO_BUILD_JOBS` and `NEXTEST_TEST_THREADS` two different ways, and `--print-env` reports which one is live as `JOBSERVER=pool` or `JOBSERVER=reserve`.

Under `pool`, `scripts/harness-jobserver.py` supervises one token pool per repository, holding a GNU make jobserver FIFO plus a Unix socket under `/tmp/harness-jobserver-<uid>/<repo-hash>/`. Cargo attaches through `CARGO_MAKEFLAGS` and renegotiates its own width for as long as it runs, so `CARGO_BUILD_JOBS` stays at the full CPU count and the pool does the limiting. The endpoint goes in `CARGO_MAKEFLAGS` rather than `MAKEFLAGS` because the `jobserver` crate honours the first of `CARGO_MAKEFLAGS`, `MAKEFLAGS`, `MFLAGS` that is set, while `make` reads only the latter two. GNU make before 4.4 does not ignore a `fifo:` endpoint it cannot parse - 4.3, which Ubuntu 24.04 ships, exits 2 with `internal error: invalid --jobserver-auth string` - so publishing one in `MAKEFLAGS` would kill every sub-make a build script runs on Linux while looking fine on a macOS box running make 4.4.

`CARGO_MAKEFLAGS` alone is not quite enough, because `cmake-rs` copies it into `MAKEFLAGS` itself for a Makefile-generator build, and `cmake` reaches this tree through `aws-lc-sys`. So the pool is only offered where the `make` on `PATH` is 4.4 or newer; anything older, or anything that does not answer with a version number, keeps the static reserve and `--print-env` reports `JOBSERVER_SKIPPED=old-make`. Stock cargo is unaffected by any of this because the jobserver it creates for itself is fd-based, which every make understands. The budget is one below the CPU count because every cargo may run a single job without holding a token; two builds sharing a four-token pool therefore peak at six concurrent `rustc`, not four.

nextest cannot speak the protocol and upstream has declined to add it, so its test width has to be fixed before the run starts. Its two halves want opposite things: the build wants the pool, and holding a block across it would starve the compile that produces the binaries the block is for. A `nextest run` is therefore split - `--no-run` builds first against the full pool, then a block comes out of the same budget through the socket and the run itself proceeds with nothing left to compile. The socket exists because a FIFO token is anonymous: a killed client would drain the pool forever, which is why the published system-wide jobservers need CUSE that macOS lacks. A socket grant returns when the kernel closes the dead client's fd.

Under `reserve` the older static split applies: each agent session divides the CPU count by `AGENT_BUILD_SHARE`, assuming that many agents may arrive, because the lease count is sampled once and cannot be renegotiated. This is the fallback whenever the pool cannot be reached, and it is what `HARNESS_JOBSERVER=0` selects. Reaching a pool is never required - a stale or empty FIFO makes cargo build serially through its implicit slot rather than block.

| Variable | Effect |
| --- | --- |
| `HARNESS_JOBSERVER=0` | Skip the pool and use the static reserve |
| `HARNESS_JOBSERVER_POOL_KEY` | Key the pool by this string instead of the repo root; tests use it for isolation |
| `HARNESS_CARGO_JOBS`, `CARGO_BUILD_JOBS` | Explicit build width, authoritative under either mode |
| `HARNESS_NEXTEST_JOBS`, `NEXTEST_TEST_THREADS` | Explicit test width; either one also suppresses the pool-backed nextest split |
| `HARNESS_JOBSERVER_TIMEOUT` | Seconds to wait for a supervisor to come up, default 15 |

A host that still reports `JOBSERVER_SKIPPED=old-make` is leaving most of itself idle: the reserve divides the CPU count by `AGENT_BUILD_SHARE`, so a lone build on a 64-core machine gets 16 jobs. Ubuntu 24.04 has no make package above 4.3, and a make installed through mise does not help because the mise shim directory sits after `/usr/bin` on `PATH` under `mise exec`. Building GNU make 4.4 or newer into `~/.local/bin` does work, because that directory precedes `/usr/bin` in both the activated shell and under `mise exec`.

## Linker, cache, and toolchain pin

Linux builds link with `mold` through a `[target.'cfg(target_os = "linux")']` entry in `.cargo/config.toml`. Cargo does not merge that table with `[build] rustflags`; once a target entry matches, the `[build]` list is dropped rather than appended to, so `--cfg tokio_unstable` is repeated inside it. macOS matches nothing and keeps reading `[build]`, which the Monitor daemon build phase depends on as its only source of rustflags. Dependencies build without debuginfo through `[profile.dev.package."*"]`, so a backtrace frame inside a dependency has no file and line; workspace crates keep theirs.

sccache caches dependencies and nothing you edit, because it declines to cache incremental compilation and workspace crates are always incremental. It also has a failure mode worth knowing: any client that finds no server starts one, and a starting server unlinks the socket before it binds, so a burst of first compilations leaves one server reachable and the rest orphaned on the same path, each still enforcing its own cache size limit over the one cache directory. `mise run clean:sccache` finds the live server by connecting and reading `SO_PEERCRED`, then stops the others. Reach for it when `~/.cache/sccache` sits far below its budget. It is Linux only, because it reads `/proc` and `SO_PEERCRED`, and the task skips itself elsewhere.

Linux builds therefore need `mold` installed, and a host without it fails deep in the link step with an unknown-linker error from `cc`. `harness:check:toolchain` checks for it alongside the pin so that failure arrives named instead.

Three files name the toolchain - `rust-toolchain.toml`, `.mise.toml`, and `mise.lock` - and cargo fingerprints rustc into every artifact, so a bump that lands in one discards the whole shared target tree the moment a cargo run resolves a different one. `harness:check:toolchain` fails when they disagree or when the pinned toolchain is not the active one. Renovate updates `rust-toolchain.toml` alone, so expect that gate to catch its PRs.

## Check lanes

`mise run check` is the per-edit gate. `mise run check:full` adds `harness:check:feature-isolation`, which checks each crate on its own so its features resolve the way they will for a dependent that selects it alone. That stays eleven separate invocations on purpose: one `--workspace` run unifies features across every selected package, so a crate that only builds because a sibling switched on an optional dependency would still pass. Run `check:full` before publishing a branch.

## Build lane and fsmonitor cleanup

The Harness Monitor xcodebuild wrapper at `apps/harness-monitor/Scripts/monitor-xcodebuild.sh` enforces a hardcoded global concurrency cap (currently 8) via a counting semaphore at `.cache/harness-monitor-xcodebuild-semaphore/`. The cap is intentionally not raisable via env var; `HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY` is rejected with a stderr warning.

The slot owner refreshes a heartbeat file every 15 seconds and records direct child PIDs to `slot/descendant_pids`, so the reaper can fall back to descendant liveness when the heartbeat file goes stale. An orphan-wrapper guard checks the initial PPID from slot acquisition against the current PPID in both the heartbeat and reaper, reclaiming slots whose owner has been reparented to launchd. The test-only override env path is the verbose triple `_HARNESS_INTERNAL_TEST_ONLY_{CONCURRENCY,AUTHORIZED,RUNNER_PID}`; setting all three with a matching PPID is the only way to lower the cap, and the wrapper logs a loud stderr warning when the override fires.

Related cleanup scripts:

- `scripts/clean-stale-fsmonitor.sh` classifies running `git fsmonitor--daemon` processes as live, orphan, redundant, or unknown and kills orphans plus redundant duplicates under `--apply`. Redundant means multiple daemons share one gitdir; the oldest are killed and the newest stays.
- `scripts/disable-fsmonitor-dormant.sh` sets `core.fsmonitor=false` per repo on repos untouched for more than `--days` days so they stop respawning daemons. Default: 30 days, dry-run. Excludes harness, kuma, kong-mesh, plugins, dotfiles, and codex-home by default.
- `scripts/launchd-fsmonitor-install.sh` installs a weekly launchd agent that runs both cleanup scripts every Sunday at 03:15 local.

Mise tasks:

```bash
mise run clean:fsmonitor
mise run clean:fsmonitor:dry-run
mise run clean:fsmonitor:disable-dormant
mise run clean:fsmonitor:disable-dormant:dry-run
mise run clean:fsmonitor:schedule
mise run clean:fsmonitor:schedule:remove
mise run clean:fsmonitor:schedule:status
```

## Versioning details

Canonical harness version source:

- `Cargo.toml`.

Derived surfaces maintained by `mise run version:*`:

- `testkit/Cargo.toml`.
- `Cargo.lock` package entries for `harness` and `harness-testkit`.
- `apps/harness-monitor/Tuist/ProjectDescriptionHelpers/BuildSettings.swift`.
- `apps/harness-monitor/Resources/LaunchAgents/io.harnessmonitor.daemon.Info.plist`.

Additional version notes:

- `src/observe/output.rs` reads SARIF `driver.version` from `env!("CARGO_PKG_VERSION")`.
- `src/cli.rs` uses Clap's derived version.

## Logging

All diagnostics use `tracing` macros:

- `warn!` for non-fatal failures, fallbacks, and degraded operations.
- `info!` for progress, phase transitions, and completion.
- `debug!` for verbose dumps.
- `println!` remains for user-facing command output and hook JSON protocol.

Use structured fields such as `warn!(%error, "failed to load context")`. Do not add `#[instrument]` unless explicitly requested. The subscriber is initialized in `main.rs`; tests run without one. Default filter: `RUST_LOG=harness=info`.

## Clippy complexity and tracing

Tracing macros can inflate `clippy::cognitive_complexity` (tokio-rs/tracing#553). When clippy flags complexity:

1. Simplify the function first.
2. Check whether tracing expansion is the only remaining driver.
3. Only then use `#[expect(clippy::cognitive_complexity)]` with this reason:

```rust
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
```

Never add that suppression as the first move.

## Grafana dashboards

Dashboards in `resources/observability/grafana/dashboards/` use Grafana 12+ responsive auto-grid layout:

- Root `layout`: `kind: "auto-grid"`, `maxColumns: 4`, `minColumnWidth: 300`.
- Stat panels: `gridPos.w: 6`.
- Time series and logs: `gridPos.w: 12`.
- Wide log viewers: `gridPos.w: 24` only when needed.
- Avoid `gridPos.w: 3` and `w: 4`.
- Panel order in JSON determines auto-grid placement.
