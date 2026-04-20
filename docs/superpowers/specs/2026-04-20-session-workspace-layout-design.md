# Session workspace layout (sub-project B)

## Background

Today a harness session lives at `~/.local/share/harness/projects/project-{8hex}/orchestration/sessions/sess-YYYYMMDDHHMMSSffffff/`. The `project-{8hex}` is the first 8 bytes of SHA256 of the canonical checkout path; the session id is a 20-digit timestamp with microseconds. Nothing creates git worktrees - sessions run against the active checkout, which means concurrent sessions on the same project race for the working tree.

The layout has four problems:

1. **Path length**. The full session directory plus `.../agents/signals/<socket>.sock` can exceed 104 bytes (the macOS `sun_path` limit) on users with long home directory paths, especially once the app group container (`~/Library/Group Containers/Q498EB36N4.io.harnessmonitor/`) becomes the data root (sub-project A).
2. **No per-session workspace**. All sessions share the checkout. Parallel agents editing the same files is chaos.
3. **No shared-agent scratch space**. Agents need a place to drop notes, handoffs, and shared context. Today they either pollute the repo or pass state through the daemon.
4. **Opaque session ids**. `sess-YYYYMMDDHHMMSSffffff` is 26 characters of mostly useless precision.

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
| Per-session subdirs | `w/` (worktree) + `s/` (shared) + sibling state files | Matches user's intent from brainstorm. State files (`state.json`, `log.jsonl`, `tasks/`, `.locks/`) live as siblings to `w/` and `s/`, not inside a metadata directory - fewer levels, same as today. |
| Session id | 8-char random alphanumeric (`[a-z0-9]{8}`) | User choice. ~2.8 × 10^12 keyspace. Collision-safe in practice. Creation time is metadata in `state.json`, not in the id. |
| Project directory name | folder basename, de-collided with `-<4hex>` suffix | Two checkouts both called `kuma` → `kuma` and `kuma-a7c2`. The 4-hex suffix is the first 4 chars of SHA256 of the canonical checkout path (same digest as today's `project-{8hex}` id, just truncated more). Deterministic and stable. |
| Sockets | Flat `<group>/sock/<sid>-<purpose>.sock` | Short absolute paths regardless of project name length. 68-byte group container prefix + `sock/` + 8-char sid + purpose = comfortably under 104. |
| Worktree owner | Daemon via subprocess `git` | Daemon already has git in PATH, already manages session lifecycle, already runs under `HARNESS_SANDBOXED` with the `temporary-exception` removed (from A). Worktree creation uses the resolved bookmark from A's `BookmarkResolver`. |
| Worktree base branch | `refs/remotes/origin/HEAD` | Falls back to current branch if origin isn't set. Session creation API exposes a `base_ref` override that sub-project C can wire into a UI later. Default matches the most common case. |
| Worktree branch name | `harness/s/<sid>` | Namespaced so it never collides with user branches. `harness/` is recognizable in `git branch --list`. |
| Cleanup on delete | `git worktree remove --force <path>` + `git branch -D harness/s/<sid>` | Atomic. If either step fails, daemon logs `warn!` and leaves the entry in `active.json` with `cleanup_failed: true` so support can recover manually. |
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
│   └── sessions/                                  (NEW from B)
│       └── <project-name>[-<4hex>]/
│           ├── <sid>/                             (8-char lowercase alphanumeric)
│           │   ├── w/                             (git worktree, branch harness/s/<sid>)
│           │   ├── s/                             (shared agent scratch)
│           │   ├── state.json
│           │   ├── log.jsonl
│           │   ├── tasks/
│           │   │   └── <task_id>/checkpoints.jsonl
│           │   └── .locks/
│           └── .active.json                       (per-project active-session registry)
├── sandbox/                                       (from A)
│   └── bookmarks.json
└── sock/                                          (NEW from B)
    └── <sid>-<purpose>.sock
```

Non-macOS (CLI-only, XDG path):

```
~/.local/share/harness/
├── sessions/<project>[-<4hex>]/<sid>/{w,s,state.json,log.jsonl,tasks/,.locks/}
└── sock/<sid>-<purpose>.sock
```

The `sock/` directory intentionally sits inside the data root on Linux/non-macOS for consistency. On macOS it's outside `harness/` because the group-container prefix is 68 bytes and every saved byte counts for socket paths.

## Components

### 1. Path primitives

Location: `src/workspace/layout.rs` (new module; replaces piecewise logic in `src/session/storage/files.rs`, `src/workspace/session.rs`, `src/context.rs`).

```rust
pub struct SessionLayout {
    pub base: PathBuf,                        // <data-root>/sessions
    pub project_name: String,                 // "kuma" or "kuma-a7c2"
    pub session_id: String,                   // 8 chars
}

impl SessionLayout {
    pub fn session_root(&self) -> PathBuf;    // <base>/<proj>/<sid>/
    pub fn worktree(&self) -> PathBuf;        // <session_root>/w/
    pub fn shared(&self) -> PathBuf;          // <session_root>/s/
    pub fn state_file(&self) -> PathBuf;      // <session_root>/state.json
    pub fn log_file(&self) -> PathBuf;        // <session_root>/log.jsonl
    pub fn tasks_dir(&self) -> PathBuf;       // <session_root>/tasks/
    pub fn locks_dir(&self) -> PathBuf;       // <session_root>/.locks/
    pub fn branch_ref(&self) -> String;       // "harness/s/<sid>"
}

pub struct ProjectNameResolver;
impl ProjectNameResolver {
    pub fn resolve(canonical_path: &Path, existing_projects_dir: &Path)
        -> Result<String, LayoutError>;      // returns "kuma" or "kuma-a7c2"
}

pub fn socket_path(base: &Path, session_id: &str, purpose: &str) -> PathBuf;
```

`ProjectNameResolver::resolve` hashes the canonical path, takes the first 4 hex chars, and checks if the base name alone is free; if it is and no existing `sessions/<base>/` has a conflicting hash marker, use the base; otherwise append `-<4hex>`. A `.origin` marker file inside each project directory records the canonical path it corresponds to so the resolver is deterministic across daemon restarts.

### 2. Session id generator

Location: `src/workspace/ids.rs` (new) or extend existing id helper.

```rust
pub fn new_session_id() -> String;            // "abc12345"
```

8 chars from `[a-z0-9]`. Uses `rand::thread_rng()`. Validation helper rejects ids outside that character class.

### 3. Worktree controller

Location: `src/workspace/worktree.rs` (new module).

```rust
pub struct WorktreeController;

impl WorktreeController {
    pub async fn create(
        origin_path: &Path,
        layout: &SessionLayout,
        base_ref: Option<&str>,
    ) -> Result<(), WorktreeError>;

    pub async fn destroy(
        origin_path: &Path,
        layout: &SessionLayout,
    ) -> Result<(), WorktreeError>;

    pub async fn health_check(
        layout: &SessionLayout,
    ) -> Result<WorktreeHealth, WorktreeError>;
}
```

`create` runs:
1. `git -C <origin> rev-parse refs/remotes/origin/HEAD` (or falls back to current branch).
2. `git -C <origin> worktree add -b harness/s/<sid> <layout.worktree()> <resolved_ref>`.
3. Seeds `<layout.shared()>` as an empty directory.
4. Writes `<layout.session_root()>/.origin` with the canonical origin path for diagnostics.

`destroy` runs:
1. `git -C <origin> worktree remove --force <layout.worktree()>`.
2. `git -C <origin> branch -D harness/s/<sid>` (tolerates "not found" as success since a cleaned worktree may already have deleted the branch).
3. `fs::remove_dir_all(<layout.session_root()>)`.

Failure modes are categorized (`WorktreeCreateFailed`, `WorktreeRemoveFailed`, `BranchDeleteFailed`) with structured fields so callers can decide between "retry", "leave for manual cleanup", or "abort session creation".

Subprocess calls use `tokio::process::Command` with inherited environment except `GIT_TERMINAL_PROMPT=0` to guarantee no interactive prompts.

### 4. Session service integration

`src/session/service/direct.rs` (existing) gains:

- A `WorktreeController` dependency.
- On `POST /v1/sessions`: resolves the incoming `project_dir` (via A's `BookmarkResolver` when sandboxed, direct path otherwise), generates `sid`, builds `SessionLayout`, invokes `WorktreeController::create`. If worktree creation fails, session creation fails atomically - no orphan state file.
- On `DELETE /v1/sessions/{id}` (new or existing): invokes `WorktreeController::destroy`.

The existing `sess-YYYYMMDDHHMMSSffffff` id generation is removed entirely. All references to `project-{8hex}`, `orchestration/`, and the old session path conventions are rewritten.

### 5. Socket path convention

New helper `src/workspace/socket_paths.rs`:

```rust
pub fn session_socket(session_id: &str, purpose: &str) -> PathBuf;
```

Returns `<sock_root>/<sid>-<purpose>.sock` where `sock_root`:

- macOS: `<group-container>/sock/` (for path budget)
- else: `<data-root>/sock/`

Every existing socket consumer is migrated to this helper. The commit (`71177d19 fix(mcp): shorten monitor registry socket path`) showed where the pressure points are; this consolidates them.

### 6. Active-session registry relocation

Today `active.json` lives at `orchestration/active.json` under each project. New location: `<data-root>/sessions/<project>/.active.json`. Contents schema stays the same (a list of active session ids for that project). `load_active_registry()` is rewritten to read from the new path.

Cross-project session discovery (`harness session list --all-projects` style) iterates `<data-root>/sessions/*/.active.json`.

### 7. Swift UI path model

`HarnessMonitorPaths.swift` already resolves the data root from A. Add:

```swift
public extension HarnessMonitorPaths {
    static func sessionsRoot(environment: HarnessMonitorEnvironment = .current) -> URL
    static func sessionRoot(projectName: String, sessionId: String,
                            environment: HarnessMonitorEnvironment = .current) -> URL
    static func sessionWorktree(projectName: String, sessionId: String) -> URL
    static func sessionShared(projectName: String, sessionId: String) -> URL
    static func socketDirectory(environment: HarnessMonitorEnvironment = .current) -> URL
}
```

All paths that referenced the old `project-{8hex}/orchestration/sessions/...` in Swift are rewritten. Existing Swift tests that hardcoded old paths are updated.

### 8. Daemon HTTP API - response shape

`POST /v1/sessions` response (`SessionMutationResponse.state`) gains the new layout fields:

```rust
pub struct SessionState {
    // ...existing fields...
    pub project_name: String,          // "kuma" or "kuma-a7c2"
    pub session_id: String,            // 8 chars
    pub worktree_path: String,
    pub shared_path: String,
    pub origin_path: String,
    pub branch_ref: String,            // "harness/s/<sid>"
}
```

Fields that existed for the old layout (`is_worktree`, `worktree_name`, `recorded_from_dir`) are removed. The wire contract is rewritten - major version bump.

## Testing strategy

### Unit (Rust)

- `workspace::layout::tests`: path-builder round-trips. Collision resolver (two identical base names → distinct directories, deterministic suffix). Session id format validation (rejects uppercase, rejects non-alphanumeric, rejects wrong length).
- `workspace::worktree::tests`: create + destroy lifecycle against a scratch `git init` repo. Origin with no `refs/remotes/origin/HEAD` falls back to current branch. Failure in branch-delete step is categorized, not silently swallowed.
- `workspace::socket_paths::tests`: generated paths fit in 104 bytes on a synthetic long home (`/Users/verylonguser@corp.example.com/`).
- `session::service::direct::tests`: worktree-creation failure aborts session creation cleanly (no state file written).

### Integration (Rust)

- `tests/integration/workspace/session_lifecycle.rs`: create session via HTTP API → worktree exists, `s/` exists, `state.json` exists, `active.json` updated. Delete session → worktree gone, branch gone, directory gone, `active.json` updated.
- `tests/integration/workspace/parallel_sessions.rs`: create two sessions against the same origin → two independent worktrees with distinct branches, no interference.
- `tests/integration/workspace/collision.rs`: two canonical paths both ending in `/kuma` → distinct project directories `kuma` and `kuma-<hash>`.

### Swift

- `HarnessMonitorKit/Tests/SessionLayoutTests.swift`: path builders match the Rust-side ones for a shared fixture.
- Existing `HarnessMonitorSessionModels` tests updated for the new `SessionState` shape.

### Quality gates

- `mise run check` clean on Rust.
- `apps/harness-monitor-macos/Scripts/run-quality-gates.sh` clean on Swift.
- `mise run test:slow` covers the end-to-end worktree lifecycle via a real temporary git repo (marked `#[ignore]` in unit tests, run as integration).

## Rollout & risks

- **Risk: `git worktree add` fails on a repo with uncommitted changes at the fallback branch.** Mitigation: fall back to `refs/remotes/origin/HEAD` first. If that ref doesn't exist, prefer a dedicated `base_ref` hint from the API caller; only as last resort use the current branch.
- **Risk: worktree cleanup leaves dangling branches when `git worktree remove` succeeded but `git branch -D` failed.** Mitigation: categorized error, marker in `active.json`, `warn!` log. Manual cleanup documented.
- **Risk: parallel session creation against the same origin races on the git index lock.** Mitigation: per-origin `fd-lock` around the git invocations. Throughput cost is negligible (session creation is a rare event).
- **Risk: session directory not cleaned if the daemon crashes mid-create.** Mitigation: on daemon startup, scan `sessions/*/<sid>/` for entries without a `state.json` and delete. Orphan cleanup is idempotent.
- **Risk: clean-cut breakage for the user's local data.** Accepted - project has no external users per user's explicit choice. User can `rm -rf ~/.local/share/harness/projects/` and `rm -rf ~/Library/Application\ Support/harness/` after upgrade.
- **Risk: socket path budget still too tight for future agent sockets.** Mitigation: `socket_paths::tests` asserts the 104-byte limit on a synthetic long home. Test fails early if a new purpose string would breach.

## Execution order (for the plan)

1. Introduce `workspace::layout` module + unit tests. Path primitives only; no call sites updated yet.
2. Introduce `workspace::ids` (8-char session id) + tests.
3. Introduce `workspace::worktree` module + unit tests against a scratch git repo.
4. Introduce `workspace::socket_paths` helper + budget-assert tests.
5. Rewrite `src/session/storage/files.rs`, `src/session/storage/registry.rs`, and related callers to use the new layout.
6. Rewrite `src/daemon/service/direct.rs` session-creation path to invoke `WorktreeController::create` with the resolved `project_dir`.
7. Add `DELETE /v1/sessions/{id}` HTTP endpoint + `WorktreeController::destroy` wiring.
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

None blocking. A couple of design points noted for the plan phase:

- The `.origin` marker file inside each project directory vs a single `.projects.json` registry at `sessions/`: the plan will pick one when implementing the `ProjectNameResolver`. Default is the `.origin` marker (distributed, no hot file).
- Whether `state.json`, `log.jsonl`, `tasks/`, `.locks/` should move into a dedicated metadata subdirectory: leaving at session root for this spec. If clutter becomes a problem in practice, easy follow-up to move them later.
