# Session workspace layout (sub-project B)

## Background

Current session state lives under `.../harness/sessions/<project-name>[-<4hex>]/<sid>/`. `SessionLayout` in `src/workspace/layout.rs` owns those paths, `src/workspace/project_resolver.rs` resolves the project directory name from the canonical checkout, and `src/workspace/worktree.rs` owns the session worktree lifecycle. The old `projects/project-{8hex}/orchestration/sessions/sess-YYYYMMDDHHMMSSffffff/` shape is obsolete for sessions, although other legacy `project_context_dir()` callers still exist for non-session artifacts.

The layout has four problems:

1. **Path length**. The full session directory plus a socket path can exceed 104 bytes (the macOS `sun_path` limit) on users with long home directory paths, especially once the app group container (`~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/`) becomes the data root.
2. **No per-session workspace**. All sessions currently need their own git worktree so concurrent runs stop trampling the active checkout.
3. **No shared-agent scratch space**. Agents need a place to drop notes, handoffs, and shared context. The new `memory/` sibling handles that.
4. **Historical opacity**. The legacy `sess-YYYYMMDDHHMMSSffffff` ids were 26 characters of mostly useless precision; the current 8-character ids are the fix this design introduced.

Sub-project A moves the data root into the app group container; this spec assumes that move has landed. Sub-project B redesigns the per-session directory convention on top.

## Goals

1. Per-session git worktree created automatically from the project's default branch.
2. Per-session shared scratch directory as a sibling to the worktree.
3. Short, human-readable session ids (8 alphanumeric chars).
4. Short, reliable socket paths that fit inside `sun_path` on any reasonable macOS home.
5. Clean filesystem grouping by project for ergonomic management (`ls` sessions for a project, `rm -rf` a project's sessions).
6. Daemon owns worktree lifecycle: creation, cleanup, branch management.

## Non-goals

- **No migration logic for old on-disk data.** The project has no external users yet; this spec does a clean cut. Every code path that references the old layout is rewritten. Old on-disk data is orphaned and harmless; the user can `rm -rf` the old tree after upgrade if they want.
- Any UI flow for session creation, project picking, or attaching external sessions - those are sub-projects C and D.
- Any sandbox/bookmark work - sub-project A.
- Multiple worktrees per session. One worktree, one session.

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Root location | `<data-root>/sessions/<project>/<sid>/` | Data root lands from A at `<group>/harness/`. `sessions/` spelled out at the top level for readability; deep names are where path pressure bites. |
| Per-session subdirs | `workspace/` (git worktree) + `memory/` (shared inter-agent scratch) + sibling state files | State files (`state.json`, `log.jsonl`, `tasks/`, `.locks/`) live as siblings to `workspace/` and `memory/`, not inside a metadata directory - fewer levels, same as today. Spelled-out names avoid cryptic single-letter directories in user-visible paths. |
| Session id | 8-char random alphanumeric (`[a-z0-9]{8}`) | User choice. ~2.8 × 10^12 keyspace. Collision-safe in practice. Creation time is metadata in `state.json`, not in the id. |
| Project directory name | folder basename, de-collided with `-<4hex>` suffix | Two checkouts both called `kuma` → `kuma` and `kuma-a7c2`. The 4-hex suffix is the first 4 chars of SHA256 of the canonical checkout path (same digest as today's `project-{8hex}` id, just truncated more). Deterministic and stable. |
| Sockets | Flat `<group>/sock/<sid>-<purpose>.sock` | Short absolute paths regardless of project name length. 68-byte group container prefix + `sock/` + 8-char sid + purpose = comfortably under 104. |
| Worktree owner | Daemon via synchronous subprocess `git` | `WorktreeController` uses `std::process::Command`, not an async wrapper. Concurrent creates are serialized by the caller; git's own index lock is the contention surface. |
| Worktree base branch | `refs/remotes/origin/HEAD` | Falls back to the current branch if `origin/HEAD` is unavailable. The session start API accepts an optional `base_ref` override. |
| Worktree branch name | `harness/<sid>` | Namespaced so it never collides with user branches. `harness/` is recognizable in `git branch --list`. |
| Cleanup on delete | `git worktree remove --force <path>` + `git branch -D harness/<sid>` | Best-effort. The controller returns categorized errors and callers log warnings before continuing with DB cleanup. There is no `cleanup_failed` field in `ActiveRegistry`. |
| Version impact | **Major** | Persisted layout changes, CLI on-disk contract breaks. Clean cut means no backward-read path. Bump in the PR that lands this. |

## Architecture

New on-disk layout (macOS, post-A):

```
~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/
├── harness/                                       (data root, from A)
│   ├── daemon/
│   │   ├── manifest.json
│   │   ├── harness.db
│   │   └── codex-endpoint.json
│   └── sessions/                                  (session layout root)
│       └── <project-name>[-<4hex>]/
│           ├── .origin                            (project directory marker for resolver)
│           ├── .active.json                       (per-project active-session registry)
│           └── <sid>/                             (8-char lowercase alphanumeric)
│               ├── workspace/                    (git worktree, branch harness/<sid>)
│               ├── memory/                       (shared inter-agent scratch)
│               ├── state.json
│               ├── log.jsonl
│               ├── tasks/
│               │   └── <task_id>/checkpoints.jsonl
│               ├── .locks/
│               └── .origin                        (session origin marker)
├── sandbox/                                       (from A)
│   └── bookmarks.json
└── sock/                                          (NEW from B)
    └── <sid>-<purpose>.sock
```

Non-macOS (CLI-only, XDG path):

```
~/.local/share/harness/
├── sessions/<project>[-<4hex>]/<sid>/{workspace,memory,state.json,log.jsonl,tasks/,.locks/}
└── sock/<sid>-<purpose>.sock
```

The `sock/` directory intentionally sits inside the data root on Linux/non-macOS for consistency. On macOS it's outside `harness/` because the group-container prefix is 68 bytes and every saved byte counts for socket paths.

## Components

### 1. Path primitives

Location: `src/workspace/layout.rs`.

```rust
pub struct SessionLayout {
    pub sessions_root: PathBuf,               // <data-root>/sessions
    pub project_name: String,                 // "kuma" or "kuma-a7c2"
    pub session_id: String,                   // 8 chars
}

impl SessionLayout {
    pub fn project_dir(&self) -> PathBuf;      // <sessions_root>/<proj>
    pub fn session_root(&self) -> PathBuf;     // <project_dir>/<sid>/
    pub fn workspace(&self) -> PathBuf;        // <session_root>/workspace/
    pub fn memory(&self) -> PathBuf;           // <session_root>/memory/
    pub fn state_file(&self) -> PathBuf;       // <session_root>/state.json
    pub fn log_file(&self) -> PathBuf;         // <session_root>/log.jsonl
    pub fn tasks_dir(&self) -> PathBuf;        // <session_root>/tasks/
    pub fn locks_dir(&self) -> PathBuf;        // <session_root>/.locks/
    pub fn origin_marker(&self) -> PathBuf;    // <session_root>/.origin
    pub fn active_registry(&self) -> PathBuf;  // <project_dir>/.active.json
    pub fn branch_ref(&self) -> String;        // "harness/<sid>"
}

pub fn sessions_root(data_root: &Path) -> PathBuf;
```

`src/workspace/project_resolver.rs` owns `resolve_name(canonical_path, sessions_root)` and `write_origin_marker(project_dir, canonical_path)`. The project-level `.origin` marker lives at `<sessions_root>/<project>/.origin` and records the canonical checkout path used for collision resolution. The session-level `.origin` marker lives at `<sessions_root>/<project>/<sid>/.origin` and is written by the worktree controller for teardown and diagnostics. These are intentionally different files and both are needed.

### 2. Session id generator

Location: `src/workspace/ids.rs` (new) or extend existing id helper.

```rust
pub fn new_session_id() -> String;            // "abc12345"
```

8 chars from `[a-z0-9]`. Uses `rand::thread_rng()`. Validation helper rejects ids outside that character class.

### 3. Worktree controller

Location: `src/workspace/worktree.rs`.

```rust
pub struct WorktreeController;

impl WorktreeController {
    pub fn create(origin_path: &Path, layout: &SessionLayout, base_ref: Option<&str>)
        -> Result<(), WorktreeError>;

    pub fn destroy(origin_path: &Path, layout: &SessionLayout) -> Result<(), WorktreeError>;
}
```

`create` runs:
1. `git -C <origin> rev-parse --abbrev-ref origin/HEAD` (or falls back to the current branch).
2. `git -C <origin> worktree add -b harness/<sid> <layout.workspace()> <resolved_ref>`.
3. Seeds `<layout.memory()>` as an empty directory.
4. Writes `<layout.origin_marker()>` with the canonical origin path for diagnostics.

`destroy` runs:
1. `git -C <origin> worktree remove --force <layout.workspace()>`.
2. `git -C <origin> branch -D harness/<sid>` (tolerates "not found" as success since a cleaned worktree may already have deleted the branch).
3. `fs::remove_dir_all(<layout.session_root()>)`.

Failure modes are categorized (`CreateFailed`, `RemoveFailed`, `BranchDeleteFailed`) with structured fields so callers can decide between "retry", "leave for manual cleanup", or "abort session creation". The implementation is synchronous and uses `std::process::Command`; concurrent creates for the same origin are serialized by the caller rather than by a dedicated fd lock.

### 4. Session service integration

`src/daemon/service/session_setup.rs` owns session creation, and `src/daemon/http/sessions.rs` routes `POST /v1/sessions` into it. The creation flow:

- Resolves the incoming `project_dir` through `sandbox::resolve_project_input()` when sandboxed, or as a direct path otherwise.
- Generates `sid` with `workspace::ids::new_session_id()`.
- Builds `SessionLayout`, resolves `project_name` with `workspace::project_resolver::resolve_name()`, writes the project-level `.origin`, and calls `WorktreeController::create(...)`.
- Writes the session state, registers the session as active, and records the project origin.
- Broadcasts the updated sessions list on success.

The evidenced lifecycle endpoints here are `POST /v1/sessions`, `POST /v1/sessions/{id}/end`, and `POST /v1/sessions/{id}/leave`. A delete route is a separate future follow-up if it is reintroduced.

### 5. Socket path convention

Helper: `src/workspace/socket_paths.rs`.

```rust
pub fn session_socket(root: &Path, session_id: &str, purpose: &str) -> PathBuf;
pub fn socket_root(data_root: &Path) -> PathBuf;
```

Returns `<sock_root>/<sid>-<purpose>.sock` where `sock_root`:

- macOS: `<group-container>/sock/` (for path budget)
- else: `<data-root>/sock/`

Every existing socket consumer is migrated to this helper. The commit (`71177d19 fix(mcp): shorten monitor registry socket path`) showed where the pressure points are; this consolidates them.

### 6. Active-session registry relocation

`active.json` now lives at `<data-root>/sessions/<project>/.active.json`. Contents schema stays the same (a map of active session ids to timestamps in `ActiveRegistry.sessions`). `load_active_registry_for(project_dir)` resolves the project root and reads from the new path.

Cross-project session discovery (`harness session list --all-projects` style) iterates `<data-root>/sessions/*/.active.json`.

### 7. Swift UI path model

`apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/HarnessMonitorPaths.swift` already resolves the data root from A. The current helpers are:

```swift
public extension HarnessMonitorPaths {
    static func sessionsRoot(using env: HarnessMonitorEnvironment = .current) -> URL
    static func sessionRoot(projectName: String, sessionId: String,
                            using env: HarnessMonitorEnvironment = .current) -> URL
    static func sessionWorktree(projectName: String, sessionId: String,
                                using env: HarnessMonitorEnvironment = .current) -> URL
    static func sessionShared(projectName: String, sessionId: String,
                              using env: HarnessMonitorEnvironment = .current) -> URL
    static func socketDirectory(using env: HarnessMonitorEnvironment = .current) -> URL
}
```

All paths that referenced the old `project-{8hex}/orchestration/sessions/...` in Swift are rewritten. Existing Swift tests that hardcoded old paths are updated.

### 8. Daemon HTTP API - response shape

`POST /v1/sessions` returns `SessionMutationResponse { state: SessionState }` on the Rust side, and the Swift client decodes that into `SessionSummary`. The session fields used by the current code are:

```rust
pub struct SessionState {
    pub project_name: String,
    pub session_id: String,
    pub worktree_path: PathBuf,
    pub shared_path: PathBuf,
    pub origin_path: PathBuf,
    pub branch_ref: String,
}
```

The older per-layout fields such as `is_worktree`, `worktree_name`, and `recorded_from_dir` are not part of this response shape. The wire contract is major-version territory because the persisted session layout changed.

## Testing strategy

### Unit (Rust)

- `workspace::layout::tests`: path-builder round-trips. Collision resolver (two identical base names → distinct directories, deterministic suffix). Session id format validation (rejects uppercase, rejects non-alphanumeric, rejects wrong length).
- `workspace::worktree::tests`: create + destroy lifecycle against a scratch `git init` repo. Origin with no `refs/remotes/origin/HEAD` falls back to the current branch. Branch-delete failures are categorized, not silently swallowed.
- `workspace::socket_paths::tests`: generated paths fit in 104 bytes on a synthetic long home (`/Users/verylonguser@corp.example.com/`).
- `src/daemon/service/tests/direct_session_start.rs`: worktree-creation failure aborts session creation cleanly (no state file written).

### Integration (Rust)

- `tests/integration/workspace/session_lifecycle.rs`: create session via HTTP API → `workspace/` exists, `memory/` exists, `state.json` exists, `active.json` updated. End/leave flows should keep the session registry consistent; delete is a future follow-up.
- `tests/integration/workspace/parallel_sessions.rs`: create two sessions against the same origin → two independent worktrees with distinct branches, no interference.
- `tests/integration/workspace/collision.rs`: two canonical paths both ending in `/kuma` → distinct project directories `kuma` and `kuma-<hash>`.

### Swift

- `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/HarnessMonitorPathsTests.swift`: path builders match the Rust-side ones for a shared fixture.
- Existing `HarnessMonitorSessionModels` tests updated for the new `SessionState` shape.

### Quality gates

- `mise run check` clean on Rust.
- `apps/harness-monitor-macos/Scripts/run-quality-gates.sh` clean on Swift.
- `mise run test:slow` covers the end-to-end worktree lifecycle via a real temporary git repo (marked `#[ignore]` in unit tests, run as integration).

## Rollout & risks

- **Risk: `git worktree add` fails on a repo with uncommitted changes at the fallback branch.** Mitigation: fall back to `refs/remotes/origin/HEAD` first. If that ref doesn't exist, prefer a dedicated `base_ref` hint from the API caller; only as last resort use the current branch.
- **Risk: worktree cleanup leaves dangling branches when `git worktree remove` succeeded but `git branch -D` failed.** Mitigation: categorized error with `warn!` logging during teardown. DB cleanup still proceeds, and manual cleanup is documented.
- **Risk: parallel session creation against the same origin races on the git index lock.** Mitigation: the caller serializes creation for a given origin; the controller surfaces git contention as a create error rather than trying to hide it.
- **Risk: session directory not cleaned if the daemon crashes mid-create.** Mitigation: on daemon startup, scan `sessions/*/<sid>/` for entries without a `state.json` and delete. Orphan cleanup is idempotent.
- **Risk: clean-cut breakage for the user's local data.** Accepted - project has no external users per user's explicit choice. User can `rm -rf ~/.local/share/harness/projects/` and `rm -rf ~/Library/Application\ Support/harness/` after upgrade.
- **Risk: socket path budget still too tight for future agent sockets.** Mitigation: `socket_paths::tests` asserts the 104-byte limit on a synthetic long home. Test fails early if a new purpose string would breach.

## Execution order (for the plan)

1. Introduce `workspace::layout` module + unit tests. Path primitives only; no call sites updated yet.
2. Introduce `workspace::ids` (8-char session id) + tests.
3. Introduce `workspace::worktree` module + unit tests against a scratch git repo.
4. Introduce `workspace::socket_paths` helper + budget-assert tests.
5. Rewrite `src/session/storage/files.rs`, `src/session/storage/registry.rs`, and related callers to use the new layout.
6. Rewrite `src/daemon/service/session_setup.rs` session-creation path to invoke `WorktreeController::create` with the resolved `project_dir`.
7. Keep the documented lifecycle surface on `POST /v1/sessions`, `POST /v1/sessions/{id}/end`, and `POST /v1/sessions/{id}/leave`; delete wiring is a future follow-up if it returns.
8. Rewrite `SessionState` wire contract (new fields, removed fields). Update every serializer/deserializer.
9. Rewrite Swift `HarnessMonitorPaths` + all Swift consumers of session paths.
10. Migrate every existing socket consumer to `socket_paths::session_socket`.
11. Orphan cleanup on daemon startup: detect leftover session directories without `state.json` and remove.
12. Update `harness session ...` CLI commands + snapshot fixtures for the new contract.
13. Bump version to the next **major** in `Cargo.toml` and run `mise run version:sync`.
14. Final cross-stack gate: `mise run check`, `run-quality-gates.sh`, `xcodebuild` build+test clean.

Each step lands as its own `-sS` signed commit.

## Follow-ups (sub-projects C and D)

This spec covers sub-project **B** only. B is a prerequisite for **C** and is orthogonal to **D**:

- **Sub-project C - Session creation from the Monitor app.** Consumes B's worktree layout by wiring the project-root bookmark from A into `POST /v1/sessions`. The API already accepts `project_dir`; C adds the UI that supplies a bookmark-resolved path. Sequenced after both A and B merge to main.
- **Sub-project D - External session discovery.** Uses A's `sessionDirectory` bookmark kind to attach sessions started outside the Monitor (CLI-only or external tooling). D works against any session that conforms to the new B layout; sessions from the old layout are orphaned and will not be attachable. Sequenced after A (and ideally B, so there's only one layout to discover).

## Open questions

None blocking. The current code uses two `.origin` markers on purpose:

- The project-level marker at `<sessions_root>/<project>/.origin` feeds `project_resolver::resolve_name()`.
- The session-level marker at `<sessions_root>/<project>/<sid>/.origin` is written by `WorktreeController::create()` and used for teardown/diagnostics.

`state.json`, `log.jsonl`, `tasks/`, and `.locks/` remain at session root for now.
