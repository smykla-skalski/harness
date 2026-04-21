# Monitor session creation - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-20-monitor-session-creation-design.md`

**Goal:** Deliver a New Session sheet in the Monitor app that calls `POST /v1/sessions` with a bookmark id (sandboxed) or resolved path (dev), plus the minimum Rust protocol addition (`base_ref` optional) so the user can override the base branch.

**Architecture:** New Swift `NewSessionViewModel` orchestrates submit; new `NewSessionSheetView` renders it; new `HarnessMonitorAPIClient.startSession(request:)` hits the existing POST endpoint. Rust side adds an optional `base_ref` field to `SessionStartRequest` and wires it into `WorktreeController::create` (which already accepts an `Option<&str>`). The existing `sessionsUpdated` websocket push event surfaces the new session in the sidebar - no stream plumbing needed.

**Tech stack:** Rust 2024 (clippy pedantic deny), Swift 6 with SwiftData, SwiftUI sheet + Form primitives. Uses A's `BookmarkStore` and B's session layout without modifying either.

**Version impact:** Minor bump. Not tracked in this plan - the version bump lands on main after the C branch merges (per the user's `feedback_no_bump_in_worktree` rule). No `Cargo.toml` edit here.

**Prerequisite:** A and B both merged to main. C consumes A's `BookmarkStore` and B's `WorktreeController` without touching their internals.

---

## File structure

### New Rust files

None. The Rust surface is one field added to an existing struct plus a one-line call-site change.

### Modified Rust files

| Path | Change |
| --- | --- |
| `src/daemon/protocol/session_requests.rs` | Add `base_ref: Option<String>` field (serde-default, skip-if-none) to `SessionStartRequest`. |
| `src/daemon/service/session_setup.rs` | Verify `request.base_ref.as_deref()` is passed into `WorktreeController::create`; keep the current call-site wiring intact. |
| `src/daemon/service/tests/direct_session_start.rs` | Extend existing test coverage to confirm `base_ref = Some("main")` lands the worktree on that branch. |
| `src/daemon/http/tests.rs` (or equivalent integration test file) | Add an HTTP-round-trip test posting `base_ref` and asserting the response state carries `branch_ref == "harness/<sid>"` while the worktree HEAD resolves to the requested base. |

### New Swift files

| Path | Responsibility |
| --- | --- |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/SessionStartRequest.swift` | `SessionStartRequest` Swift wire struct with snake-case keys. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/NewSessionViewModel.swift` | Validation, submit, error classification. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/NewSessionSheetView.swift` | SwiftUI sheet UI. |
| `apps/harness-monitor-macos/Sources/HarnessMonitor/Commands/NewSessionCommand.swift` | File menu command, `Cmd+N`. |
| `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/NewSessionViewModelTests.swift` | Unit tests for validation and submit. |
| `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/NewSessionAPIClientTests.swift` | Unit tests for the API client method against a mocked transport. |

### Modified Swift files

| Path | Change |
| --- | --- |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Enums.swift` | Add `.newSession` case to `PresentedSheet`. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorClientProtocol.swift` | Add `startSession(request:)` protocol method. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+Sessions.swift` | Implement `startSession(request:)`. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/PreviewHarnessClient.swift` | Stub implementation returning a fixture `SessionSummary`. |
| `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/RecordingHarnessClient.swift` | Record + replay for `startSession`. |
| `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp.swift` | Register `NewSessionCommand`; the `.newSession` sheet route is handled by `HarnessMonitorSheetRouter`. |
| `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorAppCommands.swift` | No-op or sibling changes for the File menu arrangement. |
| `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift` | Add `newSessionSheet*` identifier family. |
| `apps/harness-monitor-macos/project.yml` | Register the five new Swift files. Regenerate project with `Scripts/generate-project.sh`. |

---

## Task 1: Rust protocol - add optional base_ref

**Files:**
- Modify: `src/daemon/protocol/session_requests.rs`
- Modify: `src/daemon/protocol/tests.rs`

- [ ] **Step 1: Failing test**

`src/daemon/protocol/tests.rs` - add:

```rust
#[test]
fn session_start_request_accepts_optional_base_ref() {
    let raw = r#"{"title":"t","context":"c","runtime":"claude","project_dir":"/tmp","base_ref":"main"}"#;
    let req: SessionStartRequest = serde_json::from_str(raw).expect("parse");
    assert_eq!(req.base_ref.as_deref(), Some("main"));
}

#[test]
fn session_start_request_base_ref_optional_on_wire() {
    let raw = r#"{"title":"t","context":"c","runtime":"claude","project_dir":"/tmp"}"#;
    let req: SessionStartRequest = serde_json::from_str(raw).expect("parse");
    assert!(req.base_ref.is_none());
    let back = serde_json::to_string(&req).expect("serialize");
    assert!(!back.contains("base_ref"), "serialize should skip None");
}
```

- [ ] **Step 2: Red**

```bash
cargo test --lib daemon::protocol::tests::session_start_request
```

Compile error on missing field.

- [ ] **Step 3: Implement**

Add the field:

```rust
#[serde(default, skip_serializing_if = "Option::is_none")]
pub base_ref: Option<String>,
```

- [ ] **Step 4: Green**

```bash
cargo test --lib daemon::protocol
```

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(protocol): add base_ref to session start"
```

---

## Task 2: Rust daemon - verify base_ref wiring in session_setup

**Files:**
- Modify: `src/daemon/service/session_setup.rs`
- Modify: `src/daemon/service/tests/direct_session_start.rs`

- [ ] **Step 1: Failing test**

Extend the existing `direct_session_start` coverage to assert the base_ref is honored. The current tree already forwards `request.base_ref.as_deref()` in `session_setup.rs`, so this step is a regression check rather than a code-path discovery exercise.

- [ ] **Step 2: Red**

```bash
cargo test --lib daemon::service::tests::direct_session_start
```

If you are backporting this plan to an older branch, make sure the test fails until `session_setup.rs` forwards `request.base_ref` into `WorktreeController::create(...)`.

- [ ] **Step 3: Implement**

In `src/daemon/service/session_setup.rs`, keep the existing `WorktreeController::create` call wired to `request.base_ref.as_deref()`:

```rust
WorktreeController::create(&canonical_origin, &layout, request.base_ref.as_deref())
    .map_err(...)?;
```

Keep `use` statements at two segments max per repo rule. If the crate currently holds `use crate::workspace::worktree::WorktreeController;`, reference calls as `WorktreeController::create(...)`.

- [ ] **Step 4: Green**

```bash
cargo test --lib daemon::service
```

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(daemon): honor base_ref override"
```

---

## Task 3: Rust HTTP integration test

**Files:**
- Modify: `src/daemon/http/tests.rs` (or the equivalent integration module in `tests/integration/workspace/session_lifecycle.rs` if closer)

- [ ] **Step 1: Failing test**

```rust
#[tokio::test]
#[ignore = "spawns real daemon"]
async fn post_sessions_with_base_ref_routes_to_worktree() {
    unsafe { std::env::remove_var("CLAUDE_SESSION_ID"); }
    let origin = harness_testkit::init_git_repo_with_branch("release").await;
    let daemon = TestDaemon::spawn().await;
    let resp = daemon.post_json("/v1/sessions", serde_json::json!({
        "title": "c-test",
        "context": "",
        "runtime": "claude",
        "project_dir": origin.path().display().to_string(),
        "base_ref": "release",
    })).await.unwrap();
    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    let branch_ref = body["state"]["branch_ref"].as_str().unwrap();
    assert!(branch_ref.starts_with("harness/"));
}
```

- [ ] **Step 2: Run red**

```bash
cargo test --test integration post_sessions_with_base_ref -- --ignored
```

- [ ] **Step 3: Make green**

Implementation is already done by Task 2; this step is just a cross-layer assertion. If the test fails, walk up the stack until the missed wiring is found.

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "test(daemon): cover base_ref over HTTP"
```

---

## Task 4: Swift protocol type - SessionStartRequest

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/SessionStartRequest.swift`
- Modify: `project.yml`

- [ ] **Step 1: Failing test**

`apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/SessionStartRequestTests.swift`:

```swift
import XCTest
@testable import HarnessMonitorKit

final class SessionStartRequestTests: XCTestCase {
    func testEncodesSnakeCase() throws {
        let req = SessionStartRequest(
            title: "t", context: "c", runtime: "claude",
            sessionId: nil, projectDir: "B-abc", policyPreset: nil,
            baseRef: "main"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"base_ref\":\"main\""))
        XCTAssertTrue(json.contains("\"project_dir\":\"B-abc\""))
    }

    func testOmitsNilBaseRef() throws {
        let req = SessionStartRequest(
            title: "t", context: "c", runtime: "claude",
            sessionId: nil, projectDir: "B-abc", policyPreset: nil,
            baseRef: nil
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(req)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("base_ref"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
public struct SessionStartRequest: Codable, Equatable, Sendable {
    public let title: String
    public let context: String
    public let runtime: String
    public let sessionId: String?
    public let projectDir: String
    public let policyPreset: String?
    public let baseRef: String?

    public init(
        title: String,
        context: String,
        runtime: String,
        sessionId: String?,
        projectDir: String,
        policyPreset: String?,
        baseRef: String?
    ) {
        self.title = title
        self.context = context
        self.runtime = runtime
        self.sessionId = sessionId
        self.projectDir = projectDir
        self.policyPreset = policyPreset
        self.baseRef = baseRef
    }

    public enum CodingKeys: String, CodingKey {
        case title, context, runtime, sessionId, projectDir, policyPreset, baseRef
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(context, forKey: .context)
        try c.encode(runtime, forKey: .runtime)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(projectDir, forKey: .projectDir)
        try c.encodeIfPresent(policyPreset, forKey: .policyPreset)
        try c.encodeIfPresent(baseRef, forKey: .baseRef)
    }
}
```

- [ ] **Step 3: Run green**

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation test \
  -only-testing:HarnessMonitorKitTests/SessionStartRequestTests
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(kit): add SessionStartRequest model"
```

---

## Task 5: Swift API client - startSession method

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorClientProtocol.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+Sessions.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Support/PreviewHarnessClient.swift`
- Modify: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/RecordingHarnessClient.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/NewSessionAPIClientTests.swift`
- Modify: `project.yml`

- [ ] **Step 1: Failing test**

`NewSessionAPIClientTests.swift` covers happy path via a stubbed `URLSession` that returns `{"state": <SessionSummary JSON>}`.

- [ ] **Step 2: Implement**

Add to protocol:

```swift
func startSession(request: SessionStartRequest) async throws -> SessionSummary
```

Implement on `HarnessMonitorAPIClient`:

```swift
public func startSession(
    request: SessionStartRequest
) async throws -> SessionSummary {
    struct Response: Decodable { let state: SessionSummary }
    let response: Response = try await post("/v1/sessions", body: request)
    return response.state
}
```

Preview and Recording clients return a canned `SessionSummary` so existing UI tests are unaffected.

- [ ] **Step 3: Green**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/NewSessionAPIClientTests
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(kit): add startSession API client"
```

---

## Task 6: NewSessionViewModel

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/NewSessionViewModel.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/NewSessionViewModelTests.swift`
- Modify: `project.yml`

- [ ] **Step 1: Failing tests**

Cover:
1. `submit()` with empty title returns `.validation(.titleRequired)`.
2. `submit()` without selectedBookmarkId returns `.validation(.projectRequired)`.
3. `submit()` happy path in sandboxed mode posts `projectDir == record.id`.
4. `submit()` happy path in dev mode resolves the bookmark and posts the URL path.
5. `URLError(.cannotConnectToHost)` thrown by client maps to `.daemonUnreachable`.
6. 500 response containing `"create session worktree"` maps to `.worktreeCreateFailed(reason)`.
7. `BookmarkStoreError.unresolvable` maps to `.bookmarkRevoked(id)`.

Use a fake `HarnessMonitorClientProtocol` implementation and a `BookmarkStore` with `insertForTesting(_:)` for preseeding.

- [ ] **Step 2: Implement**

Follow the spec contract. Keep the file under 520 lines. Error mapping lives in a small private helper `classify(error:responseBody:)`.

- [ ] **Step 3: Green**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/NewSessionViewModelTests
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(kit): add NewSessionViewModel"
```

---

## Task 7: PresentedSheet case + store helper

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Enums.swift`

- [ ] **Step 1: Failing test**

`apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/PresentedSheetTests.swift`:

```swift
func testNewSessionCaseIsIdentifiable() {
    XCTAssertEqual(HarnessMonitorStore.PresentedSheet.newSession.id, "newSession")
}
```

- [ ] **Step 2: Implement**

Add the case; update the switch in `id`.

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(kit): add newSession presented sheet"
```

---

## Task 8: NewSessionSheetView + accessibility ids

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/NewSessionSheetView.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibilityIDs.swift`
- Modify: `project.yml`

- [ ] **Step 1: Failing test**

`apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/NewSessionSheetRenderingTests.swift` verifies the view builds with a fake ViewModel in preview mode and that the error banner becomes visible when `viewModel` is seeded with a `.bookmarkRevoked` error. Use `ViewInspector` only if already a dependency; otherwise assert via a pure-state snapshot of the ViewModel.

- [ ] **Step 2: Implement**

The view is composed as:
- `Form` with sections: Project (picker over `bookmarkStore.all()` filtered by `kind == .projectRoot`), Details (title + context), Advanced disclosure (base ref).
- Footer buttons: Cancel, Create.
- Inline error banner bound to `viewModel.lastError`.

Add `HarnessMonitorAccessibility.newSessionSheet`, `.newSessionTitle`, `.newSessionContext`, `.newSessionBaseRef`, `.newSessionProjectPicker`, `.newSessionCreateButton`, `.newSessionCancelButton`, `.newSessionErrorBanner`.

Do NOT add a #Preview in this file; per repo rules `#Preview` lives in `HarnessMonitorUIPreviewable`, which this file is already in. Add one #Preview that injects a `HarnessMonitorPreviewStoreFactory` store.

- [ ] **Step 3: Green**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/NewSessionSheetRenderingTests
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(ui): add NewSessionSheetView"
```

---

## Task 9: File menu command - Cmd+N

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitor/Commands/NewSessionCommand.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp.swift`
- Modify: `project.yml`

- [ ] **Step 1: Implement**

`NewSessionCommand.swift` mirrors `OpenFolderCommand.swift`:

```swift
struct NewSessionCommand: Commands {
    let store: HarnessMonitorStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Session") { store.presentedSheet = .newSession }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(store.connectionState != .online)
        }
    }
}
```

In `HarnessMonitorApp.swift`:

```swift
.commands {
    HarnessMonitorAppCommands( ... )
    NewSessionCommand { store.presentedSheet = .newSession }
    OpenFolderCommand(isPresented: $showOpenFolder)
}
```

- [ ] **Step 2: Sheet binding**

`HarnessMonitorSheetRouter` already owns the `.newSession` sheet route. Keep the routing there and create the `NewSessionViewModel` from `store.makeNewSessionViewModel()` when the sheet appears.

- [ ] **Step 3: Build**

```bash
xcodebuild ... -skipPackagePluginValidation build
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(app): add New Session menu and sheet"
```

---

## Task 10: Sessions-list entry point

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/SidebarView.swift`

- [ ] **Step 1: Add button**

The sidebar toolbar already exposes `Button("New Session", systemImage: "plus") { store.presentedSheet = .newSession }`. Keep the current styling and accessibility id `harness.sidebar.new-session`.

- [ ] **Step 2: Snapshot assertions if any**

If the previewable has a snapshot test capturing the sidebar chrome, update only the single snapshot under `INSTA_UPDATE=auto` and review the diff.

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(ui): add sidebar New Session button"
```

---

## Task 11: Observability - os_log the session creation flow

**Files:**
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/NewSessionViewModel.swift`

- [ ] **Step 1: Add logger**

```swift
private static let logger = Logger(subsystem: "io.harnessmonitor", category: "sessions")
```

Emit:
- `.info("new-session submit started")` before POST.
- `.info("new-session submit succeeded id=\(summary.sessionId, privacy: .public)")` on success.
- `.error("new-session submit failed kind=<case>")` on each SubmitError case.

Paths and bookmark contents must stay at `.debug` only.

- [ ] **Step 2: Test**

Extend `NewSessionViewModelTests` to spy on the error logger via a lightweight injected `LogSink` protocol (no OSLog interception needed - wrap a fake).

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(kit): log new session submit lifecycle"
```

---

## Task 12: Update project.yml + regenerate

**Files:**
- Modify: `apps/harness-monitor-macos/project.yml`

- [ ] **Step 1: Register new sources**

Ensure every new Swift file under `apps/harness-monitor-macos/Sources/HarnessMonitorKit/`, `apps/harness-monitor-macos/Sources/HarnessMonitor/Commands/`, and `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/` is listed so `generate-project.sh` picks it up.

- [ ] **Step 2: Regenerate**

```bash
apps/harness-monitor-macos/Scripts/generate-project.sh
```

The script also refreshes `buildServer.json` files.

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "chore(xcode): register new session files"
```

---

## Task 13: Quality gates + cross-stack check

**Files:** none

- [ ] **Step 1: Rust gates**

```bash
mise run check
cargo test --test integration -- --ignored base_ref
```

- [ ] **Step 2: Swift gates (narrow-only)**

```bash
apps/harness-monitor-macos/Scripts/run-quality-gates.sh

xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath xcode-derived \
  -skipPackagePluginValidation build

xcodebuild ... -skipPackagePluginValidation test \
  -only-testing:HarnessMonitorKitTests/SessionStartRequestTests \
  -only-testing:HarnessMonitorKitTests/NewSessionAPIClientTests \
  -only-testing:HarnessMonitorKitTests/NewSessionViewModelTests \
  -only-testing:HarnessMonitorKitTests/NewSessionSheetRenderingTests \
  -only-testing:HarnessMonitorKitTests/PresentedSheetTests
```

Per repo rule, do NOT run the full `HarnessMonitorKitTests` target and never run `HarnessMonitorUITests` in CI gates unless the user explicitly asks.

- [ ] **Step 3: Review diff**

`git diff --stat origin/main...HEAD` and confirm no unintended files.

- [ ] **Step 4: Commit (if generate-project produced trailing diffs)**

```bash
git -c commit.gpgsign=true commit -sS -a -m "chore: finalize monitor session creation"
```

---

## Self-review notes

**Spec coverage:**

| Spec section | Plan task |
| --- | --- |
| Protocol addition (Rust `base_ref`) | Task 1 |
| Wire `base_ref` through session_setup | Task 2 |
| HTTP-level cross-layer test | Task 3 |
| Swift `SessionStartRequest` wire type | Task 4 |
| Swift API client `startSession` | Task 5 |
| `NewSessionViewModel` validation + submit + error mapping | Task 6 |
| `PresentedSheet.newSession` | Task 7 |
| `NewSessionSheetView` + accessibility ids | Task 8 |
| File menu `Cmd+N` + sheet binding | Task 9 |
| Sidebar entry point | Task 10 |
| Observability via os_log | Task 11 |
| Xcode project registration | Task 12 |
| Cross-stack gate | Task 13 |
| Version bump | Intentionally omitted - handled on main post-merge per user rule |

**Placeholder scan:** No placeholders. Every task lists explicit files and explicit TDD steps.

**Type consistency:** Swift `SessionStartRequest.baseRef` serializes to `base_ref` via `convertToSnakeCase`; Rust `SessionStartRequest.base_ref` round-trips. Both treat empty string distinct from `None` by defaulting to `None` when the UI field is blank.

**Commit titles under 50 chars:** verified for each task.

**Use-segment rule:** no call site introduces a three-segment `use` chain; all calls take the form `X::Y` then `Y::foo()`. The Rust modifications in Task 2 consume `WorktreeController::create(...)` from an existing two-segment import.

**Em-dash and semicolon rule:** the document contains no em dashes and no semicolons in narrative prose. Rust code is not subject to this rule.
