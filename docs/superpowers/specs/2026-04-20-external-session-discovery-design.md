# External session discovery (sub-project D)

## Background

Sub-project A shipped sandboxed folder access via security-scoped bookmarks, including a reserved `BookmarkStore.Record.Kind.sessionDirectory` variant that was explicitly left unused until D. Sub-project B rewrote the on-disk session layout to `<data-root>/sessions/<project>[-<4hex>]/<sid>/{workspace, memory, state.json, log.jsonl, tasks/, .locks/}` with a per-project `.active.json` registry and a session-root `.origin` marker for session provenance. Project-level `.origin` files are used by project resolution elsewhere and are not part of this discovery contract.

A harness session can now be created in three ways today:

1. From the Monitor app (sub-project C, now shipped).
2. From the `harness` CLI against a project checkout.
3. By some external tool that writes the B layout into the data root.

Only route 1 produces an entry the Monitor app shows. Routes 2 and 3 land on disk but the Monitor has no awareness unless the daemon created them in-process. D closes that gap: the user points the Monitor at a session directory on disk and the Monitor attaches it into the existing session list, surfacing conflicts or layout mismatches with specific errors.

The sandbox spec left this capability as follow-up work. The B spec reaffirmed it as sequenced after A and B so there is exactly one layout to discover. B's layout is the contract D reads.

Current implementation status: D is now implemented across Swift, Rust, and CLI. The Monitor exposes `Attach External Session…` from `HarnessMonitorAppCommands`, presents the importer via `HarnessMonitorApp+AttachSession`, probes through `SessionDiscoveryProbe`, adopts through `HarnessMonitorStore.adoptExternalSession(...)`, and records the last attach outcome in the diagnostics pane. The daemon resolves `bookmark_id` when sandboxed, persists `external_origin` plus `adopted_at`, and `DELETE /v1/sessions/{id}` skips worktree teardown for externally rooted sessions.

## Goals

1. Monitor-app entry point "Attach External Session" that opens an `.fileImporter` filtered to directories and writes a `sessionDirectory`-kind bookmark.
2. Probe that reads the picked directory, validates it against the B layout, and returns a typed outcome: success with session preview, or a specific rejection (not-a-harness-session, wrong layout, conflict with attached session, origin unreadable).
3. Daemon adoption endpoint that takes a resolved session directory path plus a bookmark id, registers the session into the per-project `.active.json`, and adds it to the in-memory session list without creating a worktree.
4. Swift-side attach sheet with preview of `title`, `created_at`, `project_name`, plus conflict handling.
5. Observability: discovery events and errors visible in the Monitor.

## Non-goals

- Adopting sessions that do not conform to the B layout. Any pre-B session is orphaned by B's spec and stays orphaned here.
- Importing or copying a session into the Monitor's sessions-root. D attaches in place; if the picked directory is outside the sessions-root, D still attaches but flags the session as "external-root" and disables worktree-recreate actions.
- Branch or worktree repair. D assumes the worktree and branch are already in the shape B's `WorktreeController::create` leaves them. If they are not, D attaches the state record and surfaces a health warning.
- Migrating orphaned pre-B sessions. Out of scope per the B spec.
- Creating sessions. C covers that.

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| What "attached" means | The session id is present in the in-memory daemon session list and in the per-project `.active.json`, regardless of whether the Monitor created it | Matches how internal sessions appear today. One code path for list rendering, signals, observability. |
| Where the picked directory must live | Anywhere the user can read. Not required to be under sessions-root | A user may attach a session from a peer's data root, a backup, or a compatible CLI that writes elsewhere. The probe canonicalizes the path and records it verbatim. |
| External-root flag | `external_origin: Option<PathBuf>` and `adopted_at: Option<String>` on `SessionState`; origin reachability stays preview-only | Lets the Monitor distinguish attached-external sessions without inventing a persisted `origin-unreachable` flag. Any read-only banner is still ephemeral until that follow-up exists. |
| Bookmark kind | `sessionDirectory` (already reserved in A) | Matches A's decision. No new Swift enum variant needed. |
| Probe runs where | Swift side (reads `state.json` + `.origin`) before the adopt request; daemon re-validates on the server side | Client-side probe gives instant UI feedback. Server-side re-validation guards against TOCTOU and stale bookmarks. |
| Conflict policy | Same session id already attached: reject with `409 already-attached`. Same origin + different sid: attach (these are legitimately different sessions). | Session ids are globally unique random 8-char strings, so collision is treated as the user attaching the same session twice. |
| Missing `.origin` at session root | Treat as layout violation, reject with `not-a-harness-session` | B's `WorktreeController::create` writes `<session_root>/.origin`. Its absence signals either a broken session or a non-B directory. |
| Origin unreadable under sandbox | Attach succeeds, preview reports `originReachable = false` | The probe can still read `state.json`; the Monitor can surface a warning, but there is no persisted `origin-unreachable` field today. |
| Adoption transport | New `POST /v1/sessions/adopt` HTTP endpoint | Reuses existing daemon auth, request tracing, and bearer-token gating. WebSocket-only path would double the wiring cost. |
| CLI parity | New `harness session adopt <path>` subcommand | Same entry in unsandboxed contexts. Uses the same daemon endpoint. |
| Version impact | Minor | New feature, backward-compatible. `SessionState` gains two optional fields with serde defaults. `POST /v1/sessions/adopt` is a new route, not a change to an existing one. |

## Architecture

```
Swift app                                              Rust daemon
┌────────────────────────────────────┐              ┌──────────────────────────────────┐
│ "Attach External Session" command  │              │                                  │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ .fileImporter (directories only)   │              │                                  │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ BookmarkStore.add(kind:.sessionDir)│              │                                  │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ SessionDiscoveryProbe              │              │                                  │
│  - read state.json                 │              │                                  │
│  - read .origin marker             │              │                                  │
│  - shape-check (workspace/, mem/)  │              │                                  │
│  - optional origin reachability    │              │                                  │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ AttachSessionSheet (preview)       │              │                                  │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ HarnessMonitorAPIClient            │   HTTP       │ POST /v1/sessions/adopt          │
│  .adoptSession(bookmarkId, path)   │─────────────►│  1. accept bookmark_id + path    │
│                                    │              │     (resolve bookmark when       │
│                                    │              │      sandboxed)                  │
│                                    │              │  2. SessionAdopter::probe        │
│                                    │              │  3. SessionAdopter::register     │
│                                    │              │  4. mark external_origin         │
│                                    │◄─────────────│  5. return SessionState          │
│         │                          │              │                                  │
│         ▼                          │              │                                  │
│ Store inserts into sessions list   │              │                                  │
└────────────────────────────────────┘              └──────────────────────────────────┘

                            Data root (from A/B)
                            ~/Library/Group Containers/.../harness/sessions/<project>/<sid>/
                            ├── workspace/  (read-only to Monitor; daemon does not touch on destroy)
                            ├── memory/
                            ├── state.json  -- probed by both sides
                            ├── .origin     -- probed by both sides
                            └── ...
```

## Components

### 1. Swift entry point + command

Location: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorAppCommands.swift` owns the File-menu command and `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp+AttachSession.swift` owns the importer binding.

Menu item under File: "Attach External Session" with shortcut `Cmd Shift A`. It should present a second `.fileImporter` for directories only (`allowedContentTypes: [.folder]`, `allowsMultipleSelection: false`) without disturbing the existing Open Folder flow.

The fileImporter URL is already scoped for the process. The handler calls `BookmarkStore.add(url: scopedURL, kind: .sessionDirectory)` and hands the record id to `SessionDiscoveryProbe`.

### 2. Swift probe

Location: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/SessionDiscoveryProbe.swift` (existing probe; attach flow is still missing).

```swift
public struct SessionDiscoveryProbe: Sendable {
  public struct Preview: Sendable, Equatable {
    public let sessionId: String
    public let projectName: String
    public let title: String
    public let createdAt: Date
    public let originPath: String
    public let originReachable: Bool
    public let sessionRoot: URL
  }

  public enum Failure: Error, Sendable, Equatable {
    case notAHarnessSession(reason: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case belongsToAnotherProject(expected: String, found: String)
    case alreadyAttached(sessionId: String)
  }

  public func probe(url: URL) async throws -> Preview
}
```

Steps:

1. Confirm `state.json` exists at the session root. If missing: `.notAHarnessSession("missing state.json")`.
2. Decode `state.json` via the existing `HarnessMonitorSessionModels` decoder. Check `schema_version` against `SessionState.supportedSchemaVersion`. Version mismatch -> `.unsupportedSchemaVersion`.
3. Confirm `workspace/` and `memory/` directories exist. Missing either -> `.notAHarnessSession("missing workspace/memory")`.
4. Read `.origin` marker at session root. Compare with `state.origin_path` in `state.json`. Mismatch -> `.belongsToAnotherProject(expected:found:)`.
5. Check the origin path for read access. Unreachable sets `originReachable = false` but does not fail the probe.
6. Cross-check against `store.sessionSummaries`: if `state.session_id` is already in the list, return `.alreadyAttached`.

Probe runs in a detached Task. All file reads happen inside `url.withSecurityScope`.

### 3. Attach sheet

Location: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/AttachSessionSheetView.swift` (already in the tree).

The current sheet renders preview rows (`projectName`, `sessionId`, `title`, `createdAt`, workspace, memory), failure states, and the warning for `originReachable == false`. It is already driven from the live attach command and store workflow.

Sheet state lives on the existing `HarnessMonitorStore.presentedSheet`: add case `case attachExternal(bookmarkId: String, probe: SessionDiscoveryProbe.Preview?)` to `PresentedSheet` in `HarnessMonitorStore+Enums.swift`.

### 4. API client

Location: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+AdoptSession.swift` (existing client path).

Adds `adoptSession(bookmarkID: String, sessionRoot: URL) async throws -> SessionSummary`. Posts JSON body `{ "bookmark_id": "...", "session_root": "..." }` to `/v1/sessions/adopt`. On 200, decodes into `SessionSummary`. On 409 with body `{ "error": "already-attached", "session_id": "..." }`, surfaces as a typed error. On 422 with body `{ "error": "layout-violation", "reason": "..." }`, surfaces as a typed error.

### 5. Store integration

Location: the attach entry point lives in `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+ExternalSession.swift`; the adopt action remains in `HarnessMonitorStore+Sheets.swift`.

```swift
extension HarnessMonitorStore {
  public func adoptExternalSession(bookmarkID: String,
                                   preview: SessionDiscoveryProbe.Preview) async
}
```

Flow:

1. The attach command increments `store.attachSessionRequest`, and `HarnessMonitorApp+AttachSession` presents the importer.
2. On picker success, the app/store writes the bookmark, runs the probe, and sets `presentedSheet = .attachExternal(bookmarkId, preview: .init(...))`.
3. On Attach button tap, the sheet calls `adoptExternalSession`, which invokes the API client and records the outcome for diagnostics.
4. On 200, the store refreshes the session list (existing path) and dismisses the sheet. On failure, the store keeps the sheet open with the error rendered.

### 6. Rust adoption service

Location: `src/workspace/adopter.rs` (existing). Under 300 lines.

```rust
pub struct SessionAdopter;

pub struct AdoptionRequest {
    pub bookmark_id: Option<String>,
    pub session_root: PathBuf,
}

pub struct AdoptionOutcome {
    pub state: SessionState,
    pub layout: SessionLayout,
    pub external_origin: Option<PathBuf>,
}

impl SessionAdopter {
    pub fn probe(session_root: &Path) -> Result<ProbedSession, AdoptionError>;
    pub fn register(probed: ProbedSession, data_root_sessions: &Path) -> Result<AdoptionOutcome, AdoptionError>;
}
```

`probe` reads `state.json`, validates `schema_version == CURRENT_VERSION`, confirms `workspace/` and `memory/` exist, reads `.origin` marker, cross-checks with `state.origin_path`, canonicalizes paths.

`register` computes the `SessionLayout` from the probed session root, decides whether the session lives under the canonical sessions root or outside, flips `external_origin = Some(session_root)` when outside, and invokes `session_storage::register_active(&layout)`. If the layout is outside the sessions-root hierarchy, `register_active` works against the externally located `.active.json` in the sibling project directory.

### 7. New HTTP route

Location: `src/daemon/http/sessions.rs` routes to `src/daemon/http/sessions_adopt.rs`.

Current route: `POST /v1/sessions/adopt`. Handler:

1. Require auth.
2. Deserialize `{ bookmark_id, session_root }`.
3. When sandboxed on macOS, resolve the session root through `bookmark_id` first and fall back to the raw path in unsandboxed/dev flows.
4. Call `SessionAdopter::probe`, translate errors to 422 with structured body.
5. Call `SessionAdopter::register`, translate `AdoptionError::AlreadyAttached` to 409.
6. Return `SessionMutationResponse { state }`.

### 8. CLI parity

Location: `src/session/transport/session_commands.rs` and its tests.

```
harness session adopt <path> [--bookmark-id <id>]
```

Invokes the same daemon endpoint over HTTP. `--bookmark-id` is optional: when omitted, the CLI resolves the path directly (unsandboxed context). When the CLI itself runs sandboxed (rare but possible if we later ship a sandboxed CLI companion), it accepts a bookmark id.

### 9. SessionState schema additions

Location: `src/session/types/state.rs` (modified), `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift` (mirrored).

Add two optional fields:

```rust
#[serde(default, skip_serializing_if = "Option::is_none")]
pub external_origin: Option<PathBuf>,
#[serde(default, skip_serializing_if = "Option::is_none")]
pub adopted_at: Option<String>,
```

Both default to `None`, so old state files deserialize untouched. `CURRENT_VERSION` bumps to 9 with a passthrough `migrate_v8_to_v9` so the migration chain stays explicit.

### 10. Observability

- Rust: `tracing` spans under `target = "harness::adopter"`. Events: `info!` on `probe_ok`, `register_ok`; `warn!` on `probe_layout_violation`, `probe_origin_unreachable`; `error!` on `register_already_attached` (once per bookmark id, dedup handled by span context).
- Swift: `os_log` category `discovery`. Events include bookmark id, never full paths at `info` level.
- Monitor diagnostics pane includes an "External Sessions" row showing count of attached-external sessions and the last attach attempt outcome.

## Wire format

### Probe reads (Swift + Rust, identical contract)

From `<session_root>/state.json`:

```json
{
  "schema_version": 9,
  "session_id": "abc12345",
  "project_name": "kuma",
  "origin_path": "/Users/me/src/kuma",
  "worktree_path": "/Users/.../sessions/kuma/abc12345/workspace",
  "shared_path":   "/Users/.../sessions/kuma/abc12345/memory",
  "branch_ref": "harness/abc12345",
  "title": "demo",
  "created_at": "2026-04-20T12:34:56Z",
  "external_origin": null,
  "adopted_at": null
}
```

From `<session_root>/.origin`:

Single line, UTF-8 canonical path, no trailing newline required. Must match `state.origin_path` exactly after canonicalization.

### Adopt request (HTTP)

```
POST /v1/sessions/adopt
Content-Type: application/json
Authorization: Bearer <token>

{
  "bookmark_id": "B-8c5a7e1a-...",
  "session_root": "/Users/.../sessions/kuma/abc12345"
}
```

### Adopt response

Success (`200 OK`):

```json
{
  "state": { /* full SessionState with external_origin + adopted_at populated */ }
}
```

Already attached (`409 Conflict`):

```json
{ "error": "already-attached", "session_id": "abc12345" }
```

Layout violation (`422 Unprocessable Entity`):

```json
{ "error": "layout-violation", "reason": "missing workspace/" }
```

Belongs to another project (`422`):

```json
{ "error": "origin-mismatch", "expected": "/a", "found": "/b" }
```

Schema mismatch (`422`):

```json
{ "error": "unsupported-schema-version", "found": 7, "supported": 9 }
```

### Registry write (daemon side)

At `<sessions_root_of_picked_session>/<project_name>/.active.json`:

```json
{
  "sessions": {
    "abc12345": "2026-04-20T12:34:56Z"
  }
}
```

Same shape as today. For an externally rooted session the same write happens one directory up from the session root.

## Error handling

| Failure mode | Where detected | Surfaced as |
| --- | --- | --- |
| Picked directory has no `state.json` | Swift probe | `.notAHarnessSession("missing state.json")` + sheet disabled |
| `state.json` fails to decode | Swift probe | `.notAHarnessSession("malformed state.json")` |
| `state.schema_version` not supported | Swift probe + Rust adopter | `.unsupportedSchemaVersion` (Swift) / 422 (HTTP) |
| `.origin` missing | Swift probe + Rust adopter | `.notAHarnessSession("missing origin_path")` / 422 |
| `.origin` disagrees with `state.origin_path` | Swift probe + Rust adopter | `.belongsToAnotherProject(expected:found:)` / 422 `origin-mismatch` |
| `workspace/` or `memory/` missing | Swift probe + Rust adopter | `.notAHarnessSession("missing workspace/memory")` / 422 |
| Session id already attached | Swift probe (optimistic) + Rust adopter (authoritative) | `.alreadyAttached` / 409 |
| Origin unreadable under sandbox | Swift probe | `originReachable = false`; attach still succeeds; Monitor surfaces banner |
| Bookmark resolve failure on the daemon | Existing sandbox resolver | Request fails before adopt; no dedicated `bookmark-unresolvable` payload is used |
| Rename of session root mid-adopt (TOCTOU) | Rust adopter | 422 `layout-violation` on re-probe |
| Delete of an externally attached session | Existing `DELETE /v1/sessions/{id}` handler | Deregisters the session and skips `WorktreeController::destroy` when `state.external_origin.is_some()` |

## Testing strategy

### Unit (Rust)

- `workspace::adopter::probe` - fixtures covering: valid session, missing state.json, wrong schema version, `.origin` mismatch, missing `workspace/`, missing `memory/`.
- `workspace::adopter::register` - registers a valid probe, rejects a second register of the same id with `AlreadyAttached`, flips `external_origin` when the session root is outside `harness_data_root()`.

### Unit (Swift)

- `SessionDiscoveryProbeTests` - fixture directories backed by `FileManager.temporaryDirectory`. Valid session -> preview returned with expected fields. Missing `workspace/` -> `.notAHarnessSession`. Conflict with existing session id -> `.alreadyAttached`.
- `AttachSessionSheetTests` - render sheet with sample preview, confirm disabled state on each failure variant.

### Integration (Rust)

- `tests/integration/workspace/adopt_external.rs`, `#[ignore]` with `env_remove("CLAUDE_SESSION_ID")`. Spawns a daemon against a temp data root, prepopulates a B-layout session on disk, POSTs `/v1/sessions/adopt`, asserts the session lands in the list and `.active.json` gains the entry.
- `adopt_external::already_attached` - two posts for the same session id, second returns 409.
- `adopt_external::external_root` - session directory outside the daemon's sessions-root; adoption succeeds and `state.external_origin` is populated.

### Swift UI tests

Not added. Per project rules we never run the full UI suite in gates. Targeted `-only-testing:HarnessMonitorKitTests/SessionDiscoveryProbeTests` etc. only.

## Rollout and risks

- **Risk: attaching a foreign session whose origin is inaccessible under sandbox.** Mitigation: probe reports `originReachable=false` and the current UI only shows a warning. A dedicated re-authorization action is a follow-up, so the session stays effectively read-only until the user reauthorizes the origin through existing folder-bookmark flows.
- **Risk: user attaches a session, user manually deletes the directory, Monitor still lists it.** Mitigation: B's startup `orphan_cleanup` only helps for sessions under the daemon's canonical sessions root. Externally rooted sessions still need an explicit refresh / soft-remove follow-up; document that gap rather than assuming it already exists.
- **Risk: two Monitor instances on the same data root race on adopt.** Mitigation: `session_storage::register_active` takes a per-project file lock via `files::with_lock`. A second register with the same id and a full-file rewrite is idempotent.
- **Risk: delete of an externally attached session would destroy data the daemon never created.** Mitigation: the current delete path inspects `state.external_origin.is_some()` and skips `WorktreeController::destroy`, only removing the registry entry.
- **Risk: schema v8 state files on disk from B.** Mitigation: `migrate_v8_to_v9` is a no-op passthrough; existing sessions upgrade at load time, no manual migration needed.

## Execution order (for the plan)

1. `SessionState` schema bump (v9 passthrough migration) + `external_origin`, `adopted_at` fields + Rust tests.
2. Rust `SessionAdopter` probe + register + unit tests.
3. `POST /v1/sessions/adopt` HTTP route + handler tests.
4. `DELETE /v1/sessions/{id}` guard for `external_origin` + teardown tests.
5. CLI `harness session adopt <path>` + snapshot tests.
6. Swift `SessionDiscoveryProbe` + unit tests.
7. Swift `AttachSessionSheet` + preview fixture.
8. Swift store + API client integration.
9. Menu command + `.fileImporter` wiring in `HarnessMonitorApp`.
10. Integration tests (daemon + adopt end-to-end).

Each step lands as its own `-sS` signed commit.

## Open questions

- Do we want to expose an "Attach All Sessions Under This Folder" bulk flow at the outset? Ruled out for D. Sub-project E candidate if demand materializes.
- Bookmark-id persistence is not required for restart discovery in the current implementation. Adopted state persists `external_origin` and the daemon reindexes adopted external sessions on startup; persisting a bookmark id would only matter for a future re-authorization workflow.
- `harness session adopt` from a sandboxed Monitor-spawned CLI would need a bookmark id; today we don't ship such a CLI, so the flag stays optional for future use.
