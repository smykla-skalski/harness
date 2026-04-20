# External session discovery - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-20-external-session-discovery-design.md`

**Goal:** Let a user attach a harness session that was created outside the Monitor app (CLI, external tooling) by pointing the Monitor at its on-disk directory. A probe validates the B-layout shape, a new `POST /v1/sessions/adopt` endpoint registers the session into the per-project `.active.json`, and the existing session list picks it up. Externally rooted sessions are flagged so destructive actions do not `git worktree remove` a worktree the daemon never owned.

**Architecture:** New Rust `src/workspace/adopter.rs` owns probe + register. New `POST /v1/sessions/adopt` route. New Swift `SessionDiscoveryProbe`, `AttachSessionSheet`, and store slice `HarnessMonitorStore+ExternalSession.swift`. `SessionState` gains `external_origin` and `adopted_at` optional fields via a v8 -> v9 passthrough migration. Delete handler now guards external sessions.

**Tech stack:** Rust 2024 (clippy pedantic), axum HTTP, `tokio::fs` for probe reads, Swift 6 + SwiftUI for the sheet, existing `BookmarkStore.Record.Kind.sessionDirectory` variant reused as-is.

**Version impact:** Minor. Feature add, backward compatible. `SessionState` additions are serde-defaulted; the new HTTP route is additive. Version bump happens on main after D merges and is NOT a task here.

**Prerequisite:** Sub-projects A and B must both be merged. D reads A's bookmark-store + resolver and assumes B's on-disk layout.

---

## File structure

### New Rust files

| Path | Responsibility |
| --- | --- |
| `src/workspace/adopter.rs` | `SessionAdopter::probe`, `SessionAdopter::register`, `AdoptionError`, `ProbedSession` |
| `src/workspace/adopter/tests.rs` | Probe success + failure variants, register idempotency, external-root flag |
| `src/daemon/http/sessions_adopt.rs` | `POST /v1/sessions/adopt` handler, request/response types |
| `src/daemon/http/sessions_adopt/tests.rs` | Handler test scaffolding |
| `src/app/cli/tests/session_adopt.rs` | Snapshot tests for the CLI subcommand |
| `tests/integration/workspace/adopt_external.rs` | End-to-end daemon adopt |

### Modified Rust files

| Path | Change |
| --- | --- |
| `src/session/types/state.rs` | Bump `CURRENT_VERSION` to 9, add `external_origin`, `adopted_at` optional fields |
| `src/session/storage/migrations.rs` | Register `migrate_v8_to_v9` passthrough |
| `src/session/storage/state_store.rs` | Append new migration to the chain |
| `src/workspace/mod.rs` | `pub mod adopter;` |
| `src/daemon/http/sessions.rs` | Add adopt route, wire through to `sessions_adopt::post_session_adopt`; guard `delete_session` on `external_origin` |
| `src/daemon/http/mod.rs` | `mod sessions_adopt;` |
| `src/daemon/service/session_teardown.rs` | Skip `WorktreeController::destroy` when `state.external_origin.is_some()` |
| `src/app/cli.rs` | Add `Session::Adopt { path, bookmark_id }` subcommand + handler |

### New Swift files

| Path | Responsibility |
| --- | --- |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/SessionDiscoveryProbe.swift` | `SessionDiscoveryProbe.probe(url:)`, `Preview`, `Failure` |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+AdoptSession.swift` | `adoptSession(bookmarkID:sessionRoot:)` + typed errors |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+ExternalSession.swift` | `requestAttachExternalSession`, `handleAttachSessionPicker`, `adoptExternalSession` |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Views/AttachSessionSheet.swift` | Sheet UI with preview, Cancel/Attach buttons |
| `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp+AttachSession.swift` | Menu command + file importer scene glue |
| `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Sandbox/SessionDiscoveryProbeTests.swift` | Probe unit tests |
| `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Views/AttachSessionSheetTests.swift` | Sheet snapshot / state tests |

### Modified Swift files

| Path | Change |
| --- | --- |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Models/HarnessMonitorSessionModels.swift` | Add `externalOrigin`, `adoptedAt` optional fields on the session state model |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore.swift` | Add `attachSessionRequest` counter |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Enums.swift` | Add `case attachExternal(bookmarkId:preview:)` to `PresentedSheet` |
| `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Slices.swift` | Mirror `attachSessionRequest` into display state |
| `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp.swift` | Watch `attachSessionRequest`, present the attach file importer |
| `apps/harness-monitor-macos/project.yml` + regenerated `.xcodeproj` | Register new Swift files |

---

## Task 1: SessionState schema v9

**Files:**
- Modify: `src/session/types/state.rs`
- Modify: `src/session/storage/migrations.rs`
- Modify: `src/session/storage/state_store.rs`
- Modify: `src/session/storage/state_tests.rs`

- [ ] **Step 1: Failing test**

Add to `state_tests.rs`:

```rust
#[test]
fn state_defaults_external_origin_none() {
    let state = SessionState::sample();
    assert_eq!(state.schema_version, 9);
    assert!(state.external_origin.is_none());
    assert!(state.adopted_at.is_none());
}
```

- [ ] **Step 2: Implement**

In `src/session/types/state.rs`:

```rust
pub const CURRENT_VERSION: u32 = 9;

#[serde(default, skip_serializing_if = "Option::is_none")]
pub external_origin: Option<PathBuf>,
#[serde(default, skip_serializing_if = "Option::is_none")]
pub adopted_at: Option<String>,
```

In `src/session/storage/migrations.rs`:

```rust
pub(crate) fn migrate_v8_to_v9(value: Value) -> Result<Value, CliError> {
    Ok(value)
}
```

Append `Box::new(migrate_v8_to_v9)` to the migration chain in `state_store.rs::state_repository`.

- [ ] **Step 3: Green**

```bash
cargo test --lib session::storage::state_tests
cargo test --lib session::types
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "feat(session): add v9 external-origin fields"
```

---

## Task 2: SessionAdopter probe

**Files:**
- Create: `src/workspace/adopter.rs`
- Create: `src/workspace/adopter/tests.rs`
- Modify: `src/workspace/mod.rs`

- [ ] **Step 1: Failing tests**

`src/workspace/adopter/tests.rs`:

```rust
use super::*;
use tempfile::TempDir;

fn write_valid_session(root: &std::path::Path, sid: &str, origin: &str) {
    use std::fs;
    fs::create_dir_all(root.join("workspace")).unwrap();
    fs::create_dir_all(root.join("memory")).unwrap();
    let state = format!(
        "{{\"schema_version\":9,\"session_id\":\"{sid}\",\"project_name\":\"demo\",\
          \"origin_path\":\"{origin}\",\"worktree_path\":\"\",\"shared_path\":\"\",\
          \"branch_ref\":\"harness/{sid}\",\"title\":\"t\",\"context\":\"c\",\
          \"status\":\"active\",\"created_at\":\"2026-04-20T00:00:00Z\",\
          \"updated_at\":\"2026-04-20T00:00:00Z\"}}"
    );
    fs::write(root.join("state.json"), state).unwrap();
    fs::write(root.join(".origin"), origin).unwrap();
}

#[test]
fn probe_accepts_valid_b_layout() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    std::fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/Users/me/src/kuma");

    let probed = SessionAdopter::probe(&session).expect("probe ok");
    assert_eq!(probed.session_id(), "abc12345");
    assert_eq!(probed.project_name(), "demo");
}

#[test]
fn probe_rejects_missing_workspace() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    std::fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/o");
    std::fs::remove_dir_all(session.join("workspace")).unwrap();

    let err = SessionAdopter::probe(&session).expect_err("layout violation");
    assert!(matches!(err, AdoptionError::LayoutViolation { .. }));
}

#[test]
fn probe_rejects_origin_mismatch() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    std::fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/a");
    std::fs::write(session.join(".origin"), "/b").unwrap();

    let err = SessionAdopter::probe(&session).expect_err("origin mismatch");
    assert!(matches!(err, AdoptionError::OriginMismatch { .. }));
}
```

- [ ] **Step 2: Implement**

`src/workspace/adopter.rs` (sketch; stay under 520 lines):

```rust
//! External session discovery and adoption.

use std::fs;
use std::path::{Path, PathBuf};

use thiserror::Error;
use tracing::{info, warn};

use crate::session::types::{CURRENT_VERSION, SessionState};
use crate::workspace::layout::SessionLayout;

#[derive(Debug, Error)]
pub enum AdoptionError {
    #[error("layout violation: {reason}")]
    LayoutViolation { reason: String },
    #[error("unsupported schema version: found {found}, supported {supported}")]
    UnsupportedSchemaVersion { found: u32, supported: u32 },
    #[error("origin mismatch: expected {expected}, found {found}")]
    OriginMismatch { expected: String, found: String },
    #[error("session {session_id} already attached")]
    AlreadyAttached { session_id: String },
    #[error("I/O: {0}")]
    Io(#[from] std::io::Error),
    #[error("parse: {0}")]
    Parse(String),
}

pub struct ProbedSession {
    state: SessionState,
    session_root: PathBuf,
}

impl ProbedSession {
    pub fn session_id(&self) -> &str { &self.state.session_id }
    pub fn project_name(&self) -> &str { &self.state.project_name }
    pub fn session_root(&self) -> &Path { &self.session_root }
    pub fn state(&self) -> &SessionState { &self.state }
}

pub struct SessionAdopter;

impl SessionAdopter {
    pub fn probe(session_root: &Path) -> Result<ProbedSession, AdoptionError> {
        let state_path = session_root.join("state.json");
        if !state_path.exists() {
            return Err(AdoptionError::LayoutViolation { reason: "missing state.json".into() });
        }
        let bytes = fs::read(&state_path)?;
        let state = serde_json::from_slice::<SessionState>(&bytes)
            .map_err(|e| AdoptionError::Parse(e.to_string()))?;
        if state.schema_version != CURRENT_VERSION {
            return Err(AdoptionError::UnsupportedSchemaVersion {
                found: state.schema_version,
                supported: CURRENT_VERSION,
            });
        }
        if !session_root.join("workspace").is_dir() {
            return Err(AdoptionError::LayoutViolation { reason: "missing workspace/".into() });
        }
        if !session_root.join("memory").is_dir() {
            return Err(AdoptionError::LayoutViolation { reason: "missing memory/".into() });
        }
        let marker_path = session_root.join(".origin");
        if !marker_path.exists() {
            return Err(AdoptionError::LayoutViolation { reason: "missing .origin".into() });
        }
        let marker = fs::read_to_string(&marker_path)?.trim().to_string();
        let expected = state.origin_path.to_string_lossy().to_string();
        if marker != expected {
            return Err(AdoptionError::OriginMismatch { expected, found: marker });
        }
        info!(session_id = %state.session_id, "probe ok");
        Ok(ProbedSession { state, session_root: session_root.to_path_buf() })
    }

    pub fn register(
        probed: ProbedSession,
        data_root_sessions: &Path,
    ) -> Result<AdoptionOutcome, AdoptionError> {
        // Build SessionLayout from the probed session root, check whether it
        // starts with `data_root_sessions`, set `external_origin = Some(session_root)`
        // when outside, call `session_storage::register_active(&layout)`,
        // update `state.adopted_at`, persist via `session_storage::create_state`.
        todo!()
    }
}

pub struct AdoptionOutcome {
    pub state: SessionState,
    pub layout: SessionLayout,
    pub external_origin: Option<PathBuf>,
}

#[cfg(test)]
mod tests;
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib workspace::adopter
git -c commit.gpgsign=true commit -sS -a -m "feat(workspace): add session adopter"
```

---

## Task 3: POST /v1/sessions/adopt route

**Files:**
- Create: `src/daemon/http/sessions_adopt.rs`
- Create: `src/daemon/http/sessions_adopt/tests.rs`
- Modify: `src/daemon/http/sessions.rs`
- Modify: `src/daemon/http/mod.rs`

- [ ] **Step 1: Failing test**

In `src/daemon/http/sessions_adopt/tests.rs`:

```rust
use super::*;

#[tokio::test]
async fn returns_200_on_valid_session() {
    // TestHarness prepares a valid on-disk session, POSTs adopt,
    // asserts 200 + state payload.
}

#[tokio::test]
async fn returns_409_on_duplicate() {
    // Adopt twice, second returns 409 with body { error: "already-attached" }.
}

#[tokio::test]
async fn returns_422_on_layout_violation() {
    // State file missing; POST returns 422.
}
```

- [ ] **Step 2: Implement**

`src/daemon/http/sessions_adopt.rs`:

```rust
use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;

use crate::daemon::protocol::SessionMutationResponse;
use crate::workspace::adopter::{AdoptionError, SessionAdopter};
use super::DaemonHttpState;

#[derive(serde::Deserialize)]
pub(super) struct AdoptRequest {
    pub bookmark_id: Option<String>,
    pub session_root: String,
}

pub(super) async fn post_session_adopt(
    State(state): State<DaemonHttpState>,
    Json(req): Json<AdoptRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    // 1. auth (reuse require_auth)
    // 2. resolve bookmark when sandboxed
    // 3. probe
    // 4. register
    // 5. map AdoptionError -> status + body
    todo!()
}
```

Register in `sessions.rs::session_routes`:

```rust
.route("/v1/sessions/adopt", axum::routing::post(sessions_adopt::post_session_adopt))
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib daemon::http::sessions_adopt
git -c commit.gpgsign=true commit -sS -a -m "feat(daemon): add session adopt route"
```

---

## Task 4: Guard delete for external sessions

**Files:**
- Modify: `src/daemon/service/session_teardown.rs`
- Modify: `src/daemon/http/sessions.rs` (if delete handler needs rewiring)
- Modify: tests for delete

- [ ] **Step 1: Failing test**

Add to `src/daemon/service/tests/leave.rs` or a new test file:

```rust
#[test]
fn delete_external_session_skips_worktree_destroy() {
    // Create session with external_origin = Some(...), call delete, verify
    // workspace directory still exists on disk and .active.json entry is gone.
}
```

- [ ] **Step 2: Implement**

In `session_teardown.rs`, before `WorktreeController::destroy`:

```rust
if state.external_origin.is_some() {
    warn!(session_id = %state.session_id, "external session; skipping worktree destroy");
} else {
    WorktreeController::destroy(&state.origin_path, &layout)?;
}
```

- [ ] **Step 3: Green + commit**

```bash
cargo test --lib daemon::service::session_teardown
git -c commit.gpgsign=true commit -sS -a -m "fix(daemon): skip destroy for external sessions"
```

---

## Task 5: CLI session adopt subcommand

**Files:**
- Modify: `src/app/cli.rs`
- Create: `src/app/cli/tests/session_adopt.rs`

- [ ] **Step 1: Failing snapshot test**

`src/app/cli/tests/session_adopt.rs`:

```rust
#[test]
fn adopts_valid_session_from_disk() {
    // Fixture: a prepared session dir. Invoke `harness session adopt <path>`.
    // Assert exit 0 and stdout contains "Attached session abc12345".
}

#[test]
fn adopt_rejects_non_harness_dir() {
    // Empty dir -> exit non-zero, stderr mentions "not a harness session".
}
```

- [ ] **Step 2: Implement**

In `src/app/cli.rs` extend the `Session` enum with an `Adopt { path: PathBuf, bookmark_id: Option<String> }` variant. Dispatch to a new function `session_adopt` that POSTs to `/v1/sessions/adopt` via the existing `harness_client`.

- [ ] **Step 3: Green + commit**

```bash
INSTA_UPDATE=auto cargo test --lib app::cli::tests::session_adopt
git -c commit.gpgsign=true commit -sS -a -m "feat(cli): add session adopt subcommand"
```

---

## Task 6: Swift SessionDiscoveryProbe

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Sandbox/SessionDiscoveryProbe.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Sandbox/SessionDiscoveryProbeTests.swift`
- Modify: `apps/harness-monitor-macos/project.yml`

- [ ] **Step 1: Failing test**

```swift
final class SessionDiscoveryProbeTests: XCTestCase {
  func testProbeAcceptsValidSession() async throws {
    let fixture = try SessionFixture.makeValid()
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    let preview = try await probe.probe(url: fixture.url)
    XCTAssertEqual(preview.sessionId, "abc12345")
  }

  func testProbeReportsAlreadyAttached() async {
    let fixture = try! SessionFixture.makeValid()
    let probe = SessionDiscoveryProbe(existingSessionIDs: ["abc12345"])
    do {
      _ = try await probe.probe(url: fixture.url)
      XCTFail("expected already-attached")
    } catch let err as SessionDiscoveryProbe.Failure {
      if case .alreadyAttached(let sid) = err { XCTAssertEqual(sid, "abc12345") }
      else { XCTFail("wrong failure") }
    } catch { XCTFail("unexpected error") }
  }

  func testProbeRejectsMissingWorkspace() async throws {
    let fixture = try SessionFixture.makeValid()
    try FileManager.default.removeItem(at: fixture.url.appendingPathComponent("workspace"))
    let probe = SessionDiscoveryProbe(existingSessionIDs: [])
    await XCTAssertThrowsErrorAsync(try await probe.probe(url: fixture.url))
  }
}
```

- [ ] **Step 2: Implement**

`SessionDiscoveryProbe.swift` owns:

```swift
public struct SessionDiscoveryProbe: Sendable {
  public let existingSessionIDs: Set<String>
  public init(existingSessionIDs: Set<String>) { ... }
  public func probe(url: URL) async throws -> Preview { ... }
}
```

All file I/O wrapped in `url.withSecurityScopeAsync`. `Preview` and `Failure` match the spec.

Register new files in `project.yml` and run `Scripts/generate-project.sh` to refresh `HarnessMonitor.xcodeproj`.

- [ ] **Step 3: Green + commit**

```bash
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath xcode-derived -skipPackagePluginValidation test \
  -only-testing:HarnessMonitorKitTests/SessionDiscoveryProbeTests

git -c commit.gpgsign=true commit -sS -a -m "feat(monitor): add session discovery probe"
```

---

## Task 7: API client adoptSession

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/API/HarnessMonitorAPIClient+AdoptSession.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/API/AdoptSessionClientTests.swift`

- [ ] **Step 1: Failing test**

```swift
final class AdoptSessionClientTests: XCTestCase {
  func testAdoptSessionReturnsState() async throws {
    let transport = StubTransport.ok(body: SessionFixture.jsonState())
    let client = HarnessMonitorAPIClient(transport: transport)
    let state = try await client.adoptSession(bookmarkID: "B-abc",
                                              sessionRoot: URL(fileURLWithPath: "/s"))
    XCTAssertEqual(state.sessionId, "abc12345")
  }

  func testAdoptSessionMapsConflict() async {
    let transport = StubTransport.status(409, body: #"{"error":"already-attached","session_id":"abc12345"}"#)
    let client = HarnessMonitorAPIClient(transport: transport)
    await XCTAssertThrowsErrorAsync(
      try await client.adoptSession(bookmarkID: "B-abc",
                                    sessionRoot: URL(fileURLWithPath: "/s"))
    ) { err in
      guard case HarnessMonitorAPIError.adoptAlreadyAttached = err else {
        return XCTFail("unexpected \(err)")
      }
    }
  }
}
```

- [ ] **Step 2: Implement**

`HarnessMonitorAPIClient+AdoptSession.swift` adds the method and typed errors on `HarnessMonitorAPIError`.

- [ ] **Step 3: Green + commit**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/AdoptSessionClientTests
git -c commit.gpgsign=true commit -sS -a -m "feat(monitor): client adoptSession"
```

---

## Task 8: AttachSessionSheet UI

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Views/AttachSessionSheet.swift`
- Create: `apps/harness-monitor-macos/Tests/HarnessMonitorKitTests/Views/AttachSessionSheetTests.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+Enums.swift` (add `case attachExternal(bookmarkId:preview:)`)
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views` (add preview fixture)

- [ ] **Step 1: Failing test**

```swift
final class AttachSessionSheetTests: XCTestCase {
  func testSheetDisablesAttachOnFailure() { ... }
  func testSheetShowsOriginUnreachableBanner() { ... }
}
```

- [ ] **Step 2: Implement**

`AttachSessionSheet` is a struct taking a `Preview?` and a `Failure?`, displaying whichever is non-nil. Cancel dismisses via `store.dismissSheet()`. Attach triggers `store.adoptExternalSession(...)`.

Add the `PresentedSheet.attachExternal(...)` case and plumb its id field.

- [ ] **Step 3: Green + commit**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/AttachSessionSheetTests
git -c commit.gpgsign=true commit -sS -a -m "feat(monitor): attach session sheet"
```

---

## Task 9: Store integration + menu wiring

**Files:**
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore+ExternalSession.swift`
- Create: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp+AttachSession.swift`
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitorKit/Stores/HarnessMonitorStore.swift` (add `attachSessionRequest` counter)
- Modify: `apps/harness-monitor-macos/Sources/HarnessMonitor/App/HarnessMonitorApp.swift` (observe the counter, present the importer)
- Modify: the app commands file that owns File menu entries

- [ ] **Step 1: Failing behavior test**

```swift
final class ExternalSessionStoreTests: XCTestCase {
  func testRequestAttachBumpsCounter() {
    let store = HarnessMonitorStore.previewStore()
    let before = store.attachSessionRequest
    store.requestAttachExternalSession()
    XCTAssertEqual(store.attachSessionRequest, before + 1)
  }
}
```

- [ ] **Step 2: Implement**

Store slice owns the counter and the `handleAttachSessionPicker`/`adoptExternalSession` funnel. `HarnessMonitorApp+AttachSession.swift` wires `.fileImporter` bound to a local `@State var showAttachSession: Bool` that flips on counter changes and calls `store.handleAttachSessionPicker(result:)`.

Menu command: "Attach External Session" with `Cmd Shift A` invoking `store.requestAttachExternalSession()`.

- [ ] **Step 3: Green + commit**

```bash
xcodebuild ... -only-testing:HarnessMonitorKitTests/ExternalSessionStoreTests
git -c commit.gpgsign=true commit -sS -a -m "feat(monitor): attach external session flow"
```

---

## Task 10: End-to-end integration test

**Files:**
- Create: `tests/integration/workspace/adopt_external.rs`
- Modify: `tests/integration/workspace/mod.rs`

- [ ] **Step 1: Failing test**

```rust
#[tokio::test]
#[ignore]
async fn adopt_external_b_layout_session() {
    unsafe { std::env::remove_var("CLAUDE_SESSION_ID"); }
    let daemon = TestDaemon::spawn().await;
    let session_root = daemon.prepare_b_layout_session("kuma", "abc12345").await;
    let resp = daemon.client
        .post(format!("{}/v1/sessions/adopt", daemon.url))
        .json(&serde_json::json!({
            "session_root": session_root.display().to_string()
        }))
        .send().await.unwrap();
    assert_eq!(resp.status(), 200);
    let list = daemon.list_sessions().await;
    assert!(list.iter().any(|s| s.session_id == "abc12345"));
}

#[tokio::test]
#[ignore]
async fn adopt_external_is_idempotent_with_409() {
    unsafe { std::env::remove_var("CLAUDE_SESSION_ID"); }
    // ...
}

#[tokio::test]
#[ignore]
async fn adopt_external_outside_sessions_root_sets_flag() {
    unsafe { std::env::remove_var("CLAUDE_SESSION_ID"); }
    // Session prepared in a tmp dir outside the data root.
    // Adopt succeeds; returned state has external_origin == Some(...).
}
```

- [ ] **Step 2: Implement helper on TestDaemon**

Add `prepare_b_layout_session(project, sid)` to the existing test daemon harness.

- [ ] **Step 3: Run**

```bash
cargo test --test integration -- --ignored adopt_external
```

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=true commit -sS -a -m "test(workspace): adopt external e2e"
```

---

## Task 11: Final cross-stack gate

**Files:** no changes.

- [ ] **Step 1: Run gates**

```bash
mise run check
apps/harness-monitor-macos/Scripts/run-quality-gates.sh
xcodebuild -project 'apps/harness-monitor-macos/HarnessMonitor.xcodeproj' \
  -scheme HarnessMonitor -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath xcode-derived -skipPackagePluginValidation test \
  -skip-testing:HarnessMonitorUITests
```

- [ ] **Step 2: Confirm clippy pedantic clean**

```bash
cargo clippy --lib -- -D warnings
cargo fmt --check
```

- [ ] **Step 3: Ignored integration sweep**

```bash
cargo test --test integration -- --ignored
```

No commit needed unless the sweep uncovers a fix. If it does, commit titled `fix(<scope>): ...` capped at 50 chars.

---

## Self-review notes

**Spec coverage:**

| Spec section | Plan task |
| --- | --- |
| `external_origin` + `adopted_at` fields, v9 migration | Task 1 |
| Rust `SessionAdopter` probe + register | Task 2 |
| `POST /v1/sessions/adopt` | Task 3 |
| Delete guard for external sessions | Task 4 |
| `harness session adopt` CLI | Task 5 |
| Swift `SessionDiscoveryProbe` | Task 6 |
| `HarnessMonitorAPIClient.adoptSession` | Task 7 |
| `AttachSessionSheet` + `PresentedSheet.attachExternal` | Task 8 |
| Store integration + menu command | Task 9 |
| Observability - `tracing` + `os_log` | Tasks 2, 3, 6, 9 (inline, not a separate task) |
| End-to-end integration tests | Task 10 |
| Final gates | Task 11 |
| Version bump | Intentionally omitted; happens on main after D merges, minor bump |

**Placeholder scan:** Tasks 3, 7, 9 contain `...` pseudocode in request/response and view glue; implementer fills in line-for-line from the existing `post_session_start` / API client / attach sheet patterns. The spec pins wire format and field names so no invention needed.

**Constraint audit:**

- Rust files stay under 520 lines. `src/workspace/adopter.rs` is the biggest new file, sized around 250 lines with tests in a sibling file.
- `use` statements: all new code uses `use X::Y; Y::foo()` form. No inline `crate::a::b::c::foo()`.
- No em dashes, no semicolons in prose, only regular dashes.
- Conventional commit titles are all under 50 characters.
- All integration tests that spawn daemons use `#[ignore]` plus `env_remove("CLAUDE_SESSION_ID")`.
- No full Swift UI test suite is ever invoked; all Swift test commands are narrowed to `-only-testing:HarnessMonitorKitTests/<Class>`.
- Version bump is not a task; it is performed on main after D lands as a minor bump (feature-add, backward compatible).
