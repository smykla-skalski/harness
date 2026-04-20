# Monitor session creation (sub-project C)

## Background

Sub-project A landed sandboxed file access for the Monitor app, centered on `BookmarkStore` records of kind `projectRoot` persisted to the shared app-group `bookmarks.json`. Sub-project B landed the per-session worktree layout and rewired `POST /v1/sessions` so the daemon owns worktree creation. Crucially, B's `src/sandbox/project_input.rs` already canonicalizes `SessionStartRequest.project_dir` as either a plain path (dev / non-sandboxed) or a bookmark id (macOS + `HARNESS_SANDBOXED=1`).

What is still missing: there is no UI surface in the Monitor app that lets a user start a session. The existing command set (`HarnessMonitorAppCommands`) exposes Observe, End, and Open Folder, but nothing that creates a session. `HarnessMonitorAPIClient` has no `POST /v1/sessions` method yet - the daemon endpoint exists, but the Swift client and store never call it.

Sub-project C fills this gap: a New Session sheet that turns a `BookmarkStore.Record` of kind `projectRoot` plus a user-supplied title, context, runtime, and optional `base_ref` into a daemon-side worktree, observes the result through the existing `sessionsUpdated` websocket stream, and surfaces errors distinctly for bookmark failures vs daemon failures vs worktree failures.

## Goals

1. First-class "New Session" entry point: File menu item plus a discoverable button in the sessions list, routed to a single sheet.
2. Users pick a previously authorized folder from the existing `BookmarkStore` list, or reach Open Folder from the sheet to authorize a new one.
3. The sheet POSTs `/v1/sessions` with the bookmark id (sandboxed) or resolved path (dev), and renders the new session through the existing session list via `sessionsUpdated`.
4. Error surfaces distinguish: bookmark revoked or stale, daemon unreachable, worktree create failed, invalid repo (no git), and invalid `base_ref`.
5. Swift ViewModel is covered by unit tests; Rust-side protocol addition (`base_ref`) is backward compatible and covered at the wire.
6. Session creation UI is keyboard-reachable and VoiceOver-labeled.

## Non-goals

- Any change to sandbox entitlements, bookmark persistence, or the resolver. All of that was A.
- Any change to the on-disk session layout, worktree lifecycle, or socket convention. All of that was B.
- Attaching external sessions (that is sub-project D).
- Multi-select of multiple project folders or batch session creation.
- UI for editing an existing session's base ref, worktree, or branch. One-shot create only.
- Offering a session template library or saved-session presets. Runtime default only (claude).
- Scheduling or deferred session creation. The POST is synchronous.

## Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Surface | Modal sheet bound to `HarnessMonitorStore.presentedSheet = .newSession` | Matches the existing `sendSignal` sheet pattern; avoids adding a new window id. |
| Entry points | File > New Session (`Cmd+N`) plus a toolbar button in the sessions list | `Cmd+N` is already reserved conceptually but unused; installing it in the File menu aligns with platform rules. |
| Project picker | Picker over `BookmarkStore.all()` filtered to `kind == .projectRoot`, with an inline "Add Folder..." row that triggers `store.requestOpenFolder()` | Reuses A's store directly; no parallel state. |
| Wire value for project_dir | Sandboxed: pass `BookmarkStore.Record.id`. Dev: resolve the bookmark then pass `URL.path` | B's `resolve_project_input` handles both; keeps the scope guard alive across the HTTP round-trip. |
| base_ref | Optional text field; empty means daemon chooses (`origin/HEAD` fallback). Protocol adds `base_ref: Option<String>` to `SessionStartRequest`, gated `#[serde(default, skip_serializing_if = "Option::is_none")]` | Backward compatible; existing clients keep working. B's `WorktreeController::create` already takes `Option<&str>`. |
| Runtime default | `claude` hardcoded; no UI to change it in C | YAGNI until runtime-picker becomes a real need. Future extension point. |
| Title and context validation | Both trimmed. Title must be non-empty; context may be empty (the API already accepts empty `context`) | Matches `SessionStartRequest` field `context: String` (not `Option`) and `title` default-empty. |
| Error surfacing | Toast via `store.presentFailureFeedback` for transient failures; inline banner in the sheet for validation failures | Consistent with A's pattern for Open Folder failures. |
| Session list update | Rely on existing `sessionsUpdated` push event the daemon already broadcasts after `start_session_response` returns Ok | No new websocket plumbing required. |
| Version impact | Minor | Additive UI, one new optional protocol field, no wire break. |
| Scope for security-scoped resource | Start scope before POST, stop after response; even sandboxed bookmark ids are passed as ids over HTTP but the daemon holds the guard via `ProjectInputScope`. The Swift side still wraps any local validation read inside `withSecurityScope` for symmetry. | Matches A's discipline that scope lifetime should match IO lifetime. |

## Architecture

```
Swift Monitor app                                      Rust daemon
┌────────────────────────────────────────┐            ┌────────────────────────────────────────┐
│ File > New Session  (Cmd+N)            │            │                                        │
│          │                             │            │                                        │
│          ▼                             │            │                                        │
│ HarnessMonitorStore                    │            │                                        │
│  presentedSheet = .newSession          │            │                                        │
│          │                             │            │                                        │
│          ▼                             │            │                                        │
│ NewSessionSheetView                    │            │                                        │
│  - Picker<BookmarkStore.Record>        │            │                                        │
│  - TextField title                     │            │                                        │
│  - TextEditor context                  │            │                                        │
│  - TextField base_ref (optional)       │            │                                        │
│  - Submit button                       │            │                                        │
│          │                             │            │                                        │
│          ▼                             │            │                                        │
│ NewSessionViewModel (unit tested)      │            │                                        │
│  - validates fields                    │            │                                        │
│  - projectDir = sandboxed ? record.id  │  POST      │                                        │
│                           : resolvedPath   ─────────►│ POST /v1/sessions                    │
│  - runs inside withSecurityScope       │            │  SessionStartRequest                   │
│          │                             │            │  { title, context, runtime,            │
│          │                             │            │    project_dir, base_ref?, ... }       │
│          │                             │            │    │                                   │
│          │                             │            │    ▼                                   │
│          │                             │            │  sandbox::resolve_project_input        │
│          │                             │            │    │                                   │
│          │                             │            │    ▼                                   │
│          │                             │            │  session_setup::prepare_session        │
│          │                             │            │    │                                   │
│          │                             │            │    ▼                                   │
│          │                             │            │  WorktreeController::create(           │
│          │                             │            │    origin, layout, base_ref)           │
│          │                             │            │    │                                   │
│          │                             │            │  201 + SessionMutationResponse         │
│          │                             │            │                                        │
│          ▼                             │            │                                        │
│ HarnessMonitorStore                    │            │                                        │
│  - dismiss sheet                       │            │                                        │
│  - select newly created session        │            │                                        │
│          │                             │            │                                        │
│          ▼ (independently)             │            │                                        │
│ WebSocket stream                       │◄── push ───│ broadcast_sessions_list_changed        │
│  sessionsUpdated                       │            │  → SessionSummary appears in list      │
└────────────────────────────────────────┘            └────────────────────────────────────────┘
```

## Components

### 1. Protocol addition (Rust)

`src/daemon/protocol/session_requests.rs`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStartRequest {
    #[serde(default)]
    pub title: String,
    pub context: String,
    pub runtime: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub project_dir: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub policy_preset: Option<String>,
    // NEW in C:
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_ref: Option<String>,
}
```

In `src/daemon/service/session_setup.rs`, change the `WorktreeController::create(..., None)` call site to `..., request.base_ref.as_deref()`. `WorktreeController::create` already accepts an `Option<&str>` from B.

### 2. Swift wire model

`Sources/HarnessMonitorKit/Models/HarnessMonitorRequests.swift` gains:

```swift
public struct SessionStartRequest: Codable, Equatable, Sendable {
    public let title: String
    public let context: String
    public let runtime: String
    public let sessionId: String?
    public let projectDir: String
    public let policyPreset: String?
    public let baseRef: String?
}
```

`keyEncodingStrategy` is `.convertToSnakeCase` on the existing client, so `baseRef` serializes as `base_ref`.

`Sources/HarnessMonitorKit/Models/HarnessMonitorRequests.swift` mirrors `SessionMutationResponse` if it is not already present; it wraps `SessionSummary` which already exists.

### 3. API client method

`HarnessMonitorAPIClient`:

```swift
public func startSession(
    request: SessionStartRequest
) async throws -> SessionSummary {
    let response: SessionMutationResponse = try await post("/v1/sessions", body: request)
    return response.state
}
```

Protocol addition in `HarnessMonitorClientProtocol`. Preview clients (`PreviewHarnessClient`, `RecordingHarnessClient`) implement both the live and recording shapes.

### 4. NewSessionViewModel (Swift)

Location: `Sources/HarnessMonitorKit/Stores/NewSessionViewModel.swift`.

```swift
@MainActor
@Observable
public final class NewSessionViewModel {
    public enum ValidationError: Equatable, Sendable {
        case titleRequired
        case projectRequired
        case bookmarkUnavailable
    }

    public enum SubmitError: Equatable, Sendable {
        case validation(ValidationError)
        case bookmarkRevoked(id: String)
        case bookmarkStale(id: String)
        case daemonUnreachable
        case worktreeCreateFailed(reason: String)
        case invalidBaseRef(ref: String, reason: String)
        case unexpected(String)
    }

    public var title: String = ""
    public var context: String = ""
    public var baseRef: String = ""
    public var selectedBookmarkId: String?
    public private(set) var isSubmitting = false

    private let store: HarnessMonitorStore
    private let bookmarkStore: BookmarkStore
    private let client: any HarnessMonitorClientProtocol
    private let isSandboxed: () -> Bool

    public init(
        store: HarnessMonitorStore,
        bookmarkStore: BookmarkStore,
        client: any HarnessMonitorClientProtocol,
        isSandboxed: @escaping () -> Bool = Self.liveIsSandboxed
    ) {
        self.store = store
        self.bookmarkStore = bookmarkStore
        self.client = client
        self.isSandboxed = isSandboxed
    }

    public func submit() async -> Result<SessionSummary, SubmitError> { ... }

    public func availableBookmarks() async -> [BookmarkStore.Record] { ... }

    public static func liveIsSandboxed() -> Bool {
        ProcessInfo.processInfo.environment["HARNESS_SANDBOXED"] != nil
    }
}
```

The submit method:
1. Validates `title.trimmingCharacters(.whitespacesAndNewlines)` is non-empty.
2. Validates `selectedBookmarkId` is set.
3. Resolves the bookmark via `bookmarkStore.resolve(id:)`.
4. If `isSandboxed()` true: pass `record.id` as `projectDir`. Otherwise wrap `resolved.url.withSecurityScopeAsync { pass url.path }`.
5. Maps thrown errors: `BookmarkStoreError.unresolvable` -> `.bookmarkRevoked`, `ResolvedScope.isStale == true` after two refresh attempts -> `.bookmarkStale`.
6. Maps HTTP errors: URL error connection refused -> `.daemonUnreachable`; HTTP 5xx containing `"worktree"` -> `.worktreeCreateFailed`; HTTP 4xx containing `"base_ref"` or `"rev-parse"` -> `.invalidBaseRef`; otherwise `.unexpected`.
7. On success: `store.selectSession(result.sessionId)`; returns `.success(summary)`. Caller dismisses the sheet.

### 5. NewSessionSheetView

Location: `Sources/HarnessMonitorUIPreviewable/Views/NewSessionSheetView.swift`.

Form with sections:
- **Project** - Picker over `bookmarkStore.all().filter { $0.kind == .projectRoot }` showing `displayName` with `lastResolvedPath` secondary label. Inline button "Add Folder..." calls `store.requestOpenFolder()` and dismisses back to the sheet after the importer returns; the newly added record auto-selects.
- **Details** - Title TextField (required, accessibility id `harness.new-session.title`), Context TextEditor (optional, accessibility id `harness.new-session.context`).
- **Advanced (disclosure)** - Base ref TextField with placeholder "origin/HEAD" and helper text "Leave blank for the default branch".
- Footer - "Cancel" and "Create" buttons; Create disabled while `viewModel.isSubmitting`. Inline red banner renders the current `SubmitError` if any.

Accessibility identifiers for UI tests: `harness.new-session.sheet`, `.title`, `.context`, `.base-ref`, `.project-picker`, `.create-button`, `.cancel-button`, `.error-banner`.

### 6. Command and entry points

`OpenFolderCommand.swift` adds a `NewSessionCommand.swift` peer. `HarnessMonitorApp` wires a `@State private var showNewSession = false` plus a sheet modifier on `mainWindowContent`.

```swift
CommandGroup(after: .newItem) {
    Button("New Session") { store.presentedSheet = .newSession }
        .keyboardShortcut("n", modifiers: [.command])
    Button("Open Folder...") { isPresented = true }
        .keyboardShortcut("o", modifiers: [.command, .shift])
}
```

The sessions list toolbar also gets a "New Session" button that sets the same sheet.

### 7. PresentedSheet enum extension

`HarnessMonitorStore+Enums.swift`:

```swift
public enum PresentedSheet: Identifiable, Equatable {
    case sendSignal(agentID: String)
    case newSession

    public var id: String {
        switch self {
        case .sendSignal(let agentID): "sendSignal:\(agentID)"
        case .newSession: "newSession"
        }
    }
}
```

### 8. Observability

- Swift: `os_log` category `sessions`. Log `start`, `submit`, `success(sessionId)`, `failure(kind)`. Never log bookmark ids or paths at `info`; paths at `debug` only.
- Rust: no new logs; `start_session_direct_async` already logs via tracing.
- The existing `sessionsUpdated` push event surfaces the new session in the sidebar automatically. No new stream events.

## Data model

No new persisted Swift or Rust data. Consumes existing `BookmarkStore.Record` (A) and produces a `SessionSummary` (B). The only schema change is the additive `base_ref` field on `SessionStartRequest` and its matching Swift `SessionStartRequest.baseRef`.

## Error handling

| Failure | Classification | Surface |
| --- | --- | --- |
| Title empty | `.validation(.titleRequired)` | Inline banner in sheet; Create disabled. |
| No project selected | `.validation(.projectRequired)` | Inline banner. |
| `bookmarkStore == nil` | `.validation(.bookmarkUnavailable)` | Inline banner with "Open Settings" link. |
| `BookmarkStoreError.unresolvable` | `.bookmarkRevoked(id)` | Inline banner with "Reauthorize" action re-firing Open Folder. |
| Two-refresh stale loop | `.bookmarkStale(id)` | Inline banner with "Reauthorize" action. |
| `URLError.cannotConnectToHost` | `.daemonUnreachable` | Inline banner with "Start Daemon" action; reuses `store.startDaemon()`. |
| HTTP 500 with body containing "create session worktree" | `.worktreeCreateFailed(reason)` | Inline banner with reason and "Try different base ref" hint. |
| HTTP 400 with body containing "base_ref" or git `rev-parse` stderr | `.invalidBaseRef(ref, reason)` | Inline banner under the base ref field. |
| Anything else | `.unexpected(msg)` | Inline banner with support-diagnostic link. |

The sheet stays open on every failure; success dismisses the sheet, selects the new session, and drops a toast "Created session `<title>`".

## Open questions

None blocking. Two are flagged for the plan phase rather than the spec:

- Whether `Cmd+N` should also be bound in the Agents window. Default for C: main window only; extend later if users ask.
- Whether to prefer the sandboxed-bookmark id even when running unsandboxed if a bookmark is selected. Current decision: sandboxed uses id, unsandboxed uses resolved path - keeps dev mode bookmark-independent. Revisit if the resolver ever develops a reverse lookup.

## Follow-ups

- Sub-project D (external session attach) can reuse `NewSessionSheetView`'s `.fileImporter` bridge once its spec lands.
- If a runtime picker becomes desirable, add it to the Advanced disclosure group in the same sheet without a breaking protocol change (runtime is already a `String` on the wire).
- Version bump: C is a minor bump. Per the user's `feedback_no_bump_in_worktree` rule, the bump happens on main after C's branch merges and is NOT a task in this plan.
