# Monitor session creation (sub-project C)

## Background

Sub-project A landed sandboxed file access for the Monitor app, centered on `BookmarkStore` records of kind `projectRoot` persisted to the shared app-group `bookmarks.json`. Sub-project B landed the per-session worktree layout and the daemon-side worktree controller. Sub-project C is the Monitor-side wiring that uses that layout: `NewSessionCommand`, `HarnessMonitorSheetRouter`, `NewSessionViewModel`, `NewSessionSheetView`, and `HarnessMonitorAPIClient+Sessions.swift`.

The current implementation lets a user start a session from the File menu or the sidebar toolbar, pick a previously authorized `projectRoot` bookmark, and create a session through `POST /v1/sessions`. The view model keeps inline error state in `lastError`, uses a custom bookmark resolver, passes the bookmark id when sandboxed, and only the default resolver wraps `withSecurityScopeAsync`.

## Goals

1. First-class "New Session" entry point: File menu item plus sidebar toolbar button, routed to a single sheet.
2. Users pick a previously authorized folder from the existing `BookmarkStore` list, or reach Open Folder from the sheet to authorize a new one.
3. The sheet POSTs `/v1/sessions` with the bookmark id (sandboxed) or resolved path (dev), and the new session appears through the existing `sessionsUpdated` websocket stream.
4. Error surfaces distinguish: bookmark revoked or stale, daemon unreachable, worktree create failed, invalid repo (no git), and invalid `base_ref`.
5. Swift `NewSessionViewModel` is covered by unit tests; the Rust `base_ref` field is already backward compatible at the wire.
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
| Surface | Modal sheet bound to `HarnessMonitorStore.presentedSheet = .newSession` | Matches the existing `sendSignal` sheet pattern and the current `HarnessMonitorSheetRouter`. |
| Entry points | File > New Session (`Cmd+N`) plus the sidebar toolbar button | Both routes target the same `.newSession` sheet state. |
| Project picker | Picker over `BookmarkStore.all()` filtered to `kind == .projectRoot`, with an inline "Add Folder..." button that calls `store.handleImportedFolder` | Reuses A's store directly; no parallel state. |
| Wire value for project_dir | Sandboxed: pass `BookmarkStore.Record.id`. Dev: resolve the bookmark then pass `URL.path` | The default resolver owns `withSecurityScopeAsync`; the view model just injects the resolved path. |
| base_ref | Optional text field; empty means daemon chooses (`origin/HEAD` fallback). Rust and Swift both use `base_ref`/`baseRef` as the optional wire field. | Backward compatible; existing clients keep working. |
| Runtime default | `claude` hardcoded; no UI to change it in C | YAGNI until runtime-picker becomes a real need. Future extension point. |
| Title and context validation | Both trimmed. Title must be non-empty; context may be empty (the API already accepts empty `context`) | Matches `SessionStartRequest` field `context: String` (not `Option`) and `title` default-empty. |
| Error surfacing | Inline banner via `NewSessionViewModel.lastError`; no toast is used here | Consistent with the current sheet implementation. |
| Session list update | The store selects the new session after a successful POST, and the existing `sessionsUpdated` push event keeps the list in sync | No new websocket plumbing required. |
| Version impact | Minor | Additive UI, one new optional protocol field, no wire break. |
| Scope for security-scoped resource | The default bookmark resolver owns `withSecurityScopeAsync`; the sandboxed path sends the bookmark id directly and the daemon resolves it. | Keeps scope lifetime aligned with the actual filesystem read. |

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
│  - lastError stores inline failures    │            │  SessionStartRequest                   │
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

In `src/daemon/service/session_setup.rs`, the `WorktreeController::create(..., request.base_ref.as_deref())` call site is already wired.

### 2. Swift wire model

`apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/SessionStartRequest.swift` mirrors the Rust request:

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

`apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift` already contains `SessionSummary`, which is what the Swift client decodes from `state`.

### 3. API client method

`apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+Sessions.swift`:

```swift
public func startSession(
    request: SessionStartRequest
) async throws -> SessionSummary {
    struct Response: Decodable { let state: SessionSummary }
    let response: Response = try await post("/v1/sessions", body: request)
    return response.state
}
```

`HarnessMonitorClientProtocol` already includes `startSession(request:)`. Preview clients (`PreviewHarnessClient`, `RecordingHarnessClient`) implement the same shape.

### 4. NewSessionViewModel (Swift)

Location: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/NewSessionViewModel.swift`.

```swift
@MainActor
@Observable
public final class NewSessionViewModel {
    public enum ValidationError: Equatable, Sendable {
        case titleRequired
        case projectRequired
        case bookmarkUnavailable
    }

    public enum SubmitError: Error, Equatable, Sendable {
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
    public private(set) var lastError: SubmitError?

    private let store: HarnessMonitorStore
    private let bookmarkStore: BookmarkStore
    private let client: any HarnessMonitorClientProtocol
    private let isSandboxedCheck: @Sendable () -> Bool
    private let bookmarkResolver: BookmarkResolver
    private let logSink: any NewSessionLogSink

    public init(
        store: HarnessMonitorStore,
        bookmarkStore: BookmarkStore,
        client: any HarnessMonitorClientProtocol,
        isSandboxed: @Sendable @escaping () -> Bool = Self.liveIsSandboxed,
        bookmarkResolver: BookmarkResolver? = nil,
        logSink: any NewSessionLogSink = LiveNewSessionLogSink()
    ) {
        self.store = store
        self.bookmarkStore = bookmarkStore
        self.client = client
        self.isSandboxedCheck = isSandboxed
        self.bookmarkResolver = bookmarkResolver ?? Self.makeDefaultResolver(bookmarkStore: bookmarkStore)
        self.logSink = logSink
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
3. Resolves the bookmark through the injected resolver.
4. If sandboxed, passes `record.id` as `projectDir`; otherwise the default resolver returns a `URL.path` from `withSecurityScopeAsync`.
5. Maps `BookmarkStoreError.unresolvable` to `.bookmarkRevoked`, stale bookmark resolution to `.bookmarkStale`, connection refused to `.daemonUnreachable`, worktree failures to `.worktreeCreateFailed`, and `base_ref` resolution problems to `.invalidBaseRef`.
6. On success, selects the created session and clears `lastError`.

### 5. NewSessionSheetView

Location: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/NewSessionSheetView.swift`.

Form with sections:
- **Project** - Picker backed by `viewModel.availableBookmarks()` showing `displayName` with `lastResolvedPath` as the secondary label. Inline button "Add Folder..." calls `store.handleImportedFolder` through the sheet's file importer and then reloads the list.
- **Details** - Title TextField (required, accessibility id `harness.new-session.title`), Context TextEditor (optional, accessibility id `harness.new-session.context`).
- **Advanced (disclosure)** - Base ref TextField with placeholder "origin/HEAD" and helper text "Leave blank for the default branch".
- Footer - "Cancel" and "Create" buttons; Create disabled while `viewModel.isSubmitting`. Inline red banner renders `viewModel.lastError` if any.

Accessibility identifiers for UI tests: `harness.new-session.sheet`, `.title`, `.context`, `.base-ref`, `.project-picker`, `.create-button`, `.cancel-button`, `.error-banner`.

### 6. Command and entry points

`apps/harness-monitor-macos/Sources/HarnessMonitor/Commands/NewSessionCommand.swift` adds the file-menu command. `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp.swift` registers it alongside the existing `OpenFolderCommand`, and `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/HarnessMonitorSheetRouter.swift` owns the sheet routing and view-model creation.

```swift
CommandGroup(after: .newItem) {
    Button("New Session") { store.presentedSheet = .newSession }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(store.connectionState != .online)
}
```

The sidebar toolbar also gets a "New Session" button that sets the same sheet.

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
- Rust: no new logs are required for this feature; the existing daemon tracing is already in place.
- The existing `sessionsUpdated` push event surfaces the new session in the sidebar automatically. No new stream events.

## Data model

No new persisted Swift or Rust data. Consumes existing `BookmarkStore.Record` (A) and produces a `SessionSummary` (B). The only schema change is the additive `base_ref` field on `SessionStartRequest` and its matching Swift `SessionStartRequest.baseRef`.

## Error handling

| Failure | Classification | Surface |
| --- | --- | --- |
| Title empty | `.validation(.titleRequired)` | Inline banner in sheet; Create disabled. |
| No project selected | `.validation(.projectRequired)` | Inline banner. |
| Bookmark resolver unavailable | `.validation(.bookmarkUnavailable)` | Inline banner only. |
| `BookmarkStoreError.unresolvable` | `.bookmarkRevoked(id)` | Inline banner with "Reauthorize" action re-firing Open Folder. |
| Two-refresh stale loop | `.bookmarkStale(id)` | Inline banner with "Reauthorize" action. |
| `URLError.cannotConnectToHost` | `.daemonUnreachable` | Inline banner. |
| HTTP 500 with body containing "create session worktree" | `.worktreeCreateFailed(reason)` | Inline banner with reason and "Try different base ref" hint. |
| HTTP 400 with body containing "base_ref" or git `rev-parse` stderr | `.invalidBaseRef(ref, reason)` | Inline banner under the base ref field. |
| Anything else | `.unexpected(msg)` | Inline banner with support-diagnostic link. |

The sheet stays open on every failure; success dismisses the sheet and selects the new session.

## Open questions

None blocking. Two are flagged for the plan phase rather than the spec:

- Whether `Cmd+N` should also be bound in the Agents window. Default for C: main window only; extend later if users ask.
- Whether to prefer the sandboxed-bookmark id even when running unsandboxed if a bookmark is selected. Current decision: sandboxed uses id, unsandboxed uses resolved path - keeps dev mode bookmark-independent. Revisit if the resolver ever develops a reverse lookup.

## Follow-ups

- Sub-project D (external session attach) can reuse `NewSessionSheetView`'s `.fileImporter` bridge once its spec lands.
- If a runtime picker becomes desirable, add it to the Advanced disclosure group in the same sheet without a breaking protocol change (runtime is already a `String` on the wire).
- Version bump: C is a minor bump. Per the user's `feedback_no_bump_in_worktree` rule, the bump happens on main after C's branch merges and is NOT a task in this plan.
