import Foundation
import XCTest

@testable import HarnessMonitorKit

private typealias ReviewBodySetContinuation =
  CheckedContinuation<ReviewBodySetOutcome, Never>

@MainActor
final class HarnessMonitorStoreReviewBodyUpdateTests: XCTestCase {
  private func makeStore(client: RecordingHarnessClient) throws -> HarnessMonitorStore {
    let harness = try PersistenceIntegrationTestHarness()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.connectionState = .online
    store.client = client
    store.reviewBodies.clear()
    return store
  }

  private func seedCache(
    store: HarnessMonitorStore,
    id: String,
    body: String,
    prUpdatedAt: String = "2026-05-21T00:00:00Z",
    fetchedAt: String = "2026-05-21T00:00:00Z"
  ) {
    store.reviewBodies.store(
      pullRequestID: id,
      body: body,
      prUpdatedAt: prUpdatedAt,
      fetchedAt: fetchedAt
    )
    store.reviewBodyState[id] = .loaded(body)
  }

  func testUpdatedOutcomeConfirmsOptimisticBody() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    client.configureReviewBodyUpdate(
      pullRequestID: id,
      outcome: .updated,
      currentBody: "- [x] rebase",
      prUpdatedAt: "2026-05-22T00:00:00Z",
      fetchedAt: "2026-05-22T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: "- [ ] rebase")

    let outcome = await store.setReviewBody(
      pullRequestID: id,
      newBody: "- [x] rebase",
      priorBody: "- [ ] rebase"
    )

    XCTAssertEqual(outcome, .updated)
    XCTAssertEqual(client.reviewBodyUpdateCallCount(), 1)
    if case .loaded(let body) = store.reviewBodyState[id] {
      XCTAssertEqual(body, "- [x] rebase")
    } else {
      XCTFail("expected loaded state after successful update")
    }
    XCTAssertEqual(store.reviewBodies.cached(forPullRequestID: id)?.body, "- [x] rebase")
    XCTAssertEqual(
      store.reviewBodies.cached(forPullRequestID: id)?.prUpdatedAt,
      "2026-05-22T00:00:00Z"
    )
  }

  func testBodyDriftedReplacesOptimisticWithReturnedCurrent() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    client.configureReviewBodyUpdate(
      pullRequestID: id,
      outcome: .bodyDrifted,
      currentBody: "- [ ] rebase\n- [ ] new check from teammate",
      prUpdatedAt: "2026-05-22T00:00:00Z",
      fetchedAt: "2026-05-22T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: "- [ ] rebase")

    let outcome = await store.setReviewBody(
      pullRequestID: id,
      newBody: "- [x] rebase",
      priorBody: "- [ ] rebase"
    )

    XCTAssertEqual(outcome, .bodyDrifted)
    if case .loaded(let body) = store.reviewBodyState[id] {
      XCTAssertEqual(body, "- [ ] rebase\n- [ ] new check from teammate")
    } else {
      XCTFail("expected loaded state with daemon-returned body after drift")
    }
    XCTAssertEqual(
      store.reviewBodies.cached(forPullRequestID: id)?.body,
      "- [ ] rebase\n- [ ] new check from teammate"
    )
  }

  func testTransportErrorRevertsToPriorBody() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    client.configureReviewBodyUpdateError(
      pullRequestID: id,
      error: HarnessMonitorAPIError.server(code: 500, message: "kaboom")
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: "- [ ] rebase")

    let outcome = await store.setReviewBody(
      pullRequestID: id,
      newBody: "- [x] rebase",
      priorBody: "- [ ] rebase"
    )

    switch outcome {
    case .failed(let message):
      XCTAssertFalse(message.isEmpty)
    case .updated, .bodyDrifted:
      XCTFail("expected failed outcome, got \(outcome)")
    }
    if case .loaded(let body) = store.reviewBodyState[id] {
      XCTAssertEqual(body, "- [ ] rebase")
    } else {
      XCTFail("expected revert to prior body")
    }
    XCTAssertEqual(store.reviewBodies.cached(forPullRequestID: id)?.body, "- [ ] rebase")
  }

  func testMissingDaemonReturnsFailedAndReverts() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: "- [ ] rebase")
    store.client = nil

    let outcome = await store.setReviewBody(
      pullRequestID: id,
      newBody: "- [x] rebase",
      priorBody: "- [ ] rebase"
    )

    XCTAssertEqual(outcome, .failed("Daemon unavailable"))
    if case .loaded(let body) = store.reviewBodyState[id] {
      XCTAssertEqual(body, "- [ ] rebase")
    } else {
      XCTFail("expected loaded state after revert")
    }
  }

  func testSendsSHA256OfPriorBodyAsExpectedHash() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    let priorBody = "- [ ] rebase\n"
    client.configureReviewBodyUpdate(
      pullRequestID: id,
      outcome: .updated,
      currentBody: "- [x] rebase\n"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: priorBody)

    _ = await store.setReviewBody(
      pullRequestID: id,
      newBody: "- [x] rebase\n",
      priorBody: priorBody
    )

    let expectedHash = HarnessMonitorStore.sha256Hex(of: priorBody)
    let recorded = client.reviewBodyUpdateRequests
    XCTAssertEqual(recorded.count, 1)
    XCTAssertEqual(recorded.first?.expectedPriorBodySHA256, expectedHash)
    XCTAssertEqual(expectedHash.count, 64)
  }

  func testSHA256HelperMatchesKnownEmptyDigest() {
    XCTAssertEqual(
      HarnessMonitorStore.sha256Hex(of: ""),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
  }

  func testCoalesceCoalescesRapidClicksIntoSingleDaemonWrite() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    let priorBody = "- [ ] rebase\n"
    let intermediate = "- [x] rebase\n"
    let finalBody = "- [ ] rebase\n"
    client.configureReviewBodyUpdate(
      pullRequestID: id,
      outcome: .updated,
      currentBody: finalBody
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: priorBody)

    let outcome = await withCheckedContinuation { (continuation: ReviewBodySetContinuation) in
      store.coalesceReviewBodyEdit(
        pullRequestID: id, newBody: intermediate, priorBody: priorBody, debounceMillis: 30
      )
      store.coalesceReviewBodyEdit(
        pullRequestID: id, newBody: finalBody, priorBody: intermediate, debounceMillis: 30
      ) { result in continuation.resume(returning: result) }
    }

    XCTAssertEqual(outcome, .updated)
    XCTAssertEqual(client.reviewBodyUpdateCallCount(), 1)
    let recorded = client.reviewBodyUpdateRequests.first
    XCTAssertEqual(recorded?.newBody, finalBody)
    XCTAssertEqual(
      recorded?.expectedPriorBodySHA256, HarnessMonitorStore.sha256Hex(of: priorBody))
  }

  func testCoalesceFlipsLocalBodyStateImmediately() async throws {
    let client = RecordingHarnessClient()
    let id = "PR_1"
    let priorBody = "- [ ] rebase\n"
    client.configureReviewBodyUpdate(
      pullRequestID: id, outcome: .updated, currentBody: "- [x] rebase\n")
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    seedCache(store: store, id: id, body: priorBody)

    store.coalesceReviewBodyEdit(
      pullRequestID: id,
      newBody: "- [x] rebase\n",
      priorBody: priorBody,
      debounceMillis: 1_000
    )

    if case .loaded(let body) = store.reviewBodyState[id] {
      XCTAssertEqual(body, "- [x] rebase\n")
    } else {
      XCTFail("expected optimistic loaded state")
    }
    XCTAssertEqual(client.reviewBodyUpdateCallCount(), 0)
    store.pendingReviewBodyEdits[id]?.task.cancel()
    store.pendingReviewBodyEdits[id] = nil
  }
}
