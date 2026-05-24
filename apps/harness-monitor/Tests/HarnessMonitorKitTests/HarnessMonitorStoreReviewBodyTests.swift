import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreReviewBodyTests: XCTestCase {
  private func makeItem(
    pullRequestID: String = "PR_1",
    updatedAt: String = "2026-05-21T00:00:00Z"
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: "repo_1",
      repository: "acme/api",
      number: 42,
      title: "chore(deps): bump foo",
      url: "https://example.com",
      authorLogin: "renovate[bot]",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc",
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-20T00:00:00Z",
      updatedAt: updatedAt
    )
  }

  private func makeStore(client: RecordingHarnessClient) throws -> HarnessMonitorStore {
    let harness = try PersistenceIntegrationTestHarness()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
    store.connectionState = .online
    store.client = client
    // Use a fresh body cache so tests don't pollute the global UserDefaults.
    store.reviewBodies.clear()
    return store
  }

  func testCacheMissTriggersFetchAndPublishesLoaded() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewBody(
      pullRequestID: "PR_1",
      body: "Hello world",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    await store.prepareReviewBody(for: item)

    XCTAssertEqual(client.reviewBodyFetchCount(), 1)
    if case .loaded(let body) = store.reviewBodyState["PR_1"] {
      XCTAssertEqual(body, "Hello world")
    } else {
      XCTFail("expected .loaded state")
    }
  }

  func testCacheHitSkipsClient() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewBody(
      pullRequestID: "PR_1",
      body: "First",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    await store.prepareReviewBody(for: item)
    XCTAssertEqual(client.reviewBodyFetchCount(), 1)

    await store.prepareReviewBody(for: item)
    XCTAssertEqual(client.reviewBodyFetchCount(), 1, "Cache hit must skip client")
    if case .loaded(let body) = store.reviewBodyState["PR_1"] {
      XCTAssertEqual(body, "First")
    } else {
      XCTFail("expected .loaded state")
    }
  }

  func testUpdatedAtAdvanceTriggersRefetch() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewBody(
      pullRequestID: "PR_1",
      body: "Old",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    let stale = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")
    await store.prepareReviewBody(for: stale)
    XCTAssertEqual(client.reviewBodyFetchCount(), 1)

    client.configureReviewBody(
      pullRequestID: "PR_1",
      body: "Fresh",
      prUpdatedAt: "2026-05-21T00:30:00Z"
    )
    let fresh = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:30:00Z")
    await store.prepareReviewBody(for: fresh)

    XCTAssertEqual(client.reviewBodyFetchCount(), 2, "Advanced updatedAt must invalidate cache")
    if case .loaded(let body) = store.reviewBodyState["PR_1"] {
      XCTAssertEqual(body, "Fresh")
    } else {
      XCTFail("expected .loaded state with fresh body")
    }
  }

  func testConcurrentFetchesDedupe() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewBody(
      pullRequestID: "PR_1",
      body: "Body",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let gate = AsyncSemaphore()
    client.setReviewBodyFetchHook { _ in await gate.wait() }

    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    async let first: () = store.prepareReviewBody(for: item)
    await Task.yield()
    await Task.yield()
    async let second: () = store.prepareReviewBody(for: item)
    await Task.yield()
    await Task.yield()

    gate.signal()
    _ = await (first, second)

    XCTAssertEqual(
      client.reviewBodyFetchCount(),
      1,
      "concurrent prepare calls must collapse to one client fetch"
    )
  }

  func testTaskKeyChangesWhenDaemonComesOnline() {
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")
    let offline = ReviewBodyTaskKey(item: item, isDaemonOnline: false)
    let online = ReviewBodyTaskKey(item: item, isDaemonOnline: true)
    XCTAssertNotEqual(
      offline,
      online,
      "task key must flip identity when daemon comes back online so SwiftUI .task(id:) re-fires"
    )
  }

  func testTaskKeyChangesWhenPRUpdatedAtAdvances() {
    let original = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")
    let edited = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T01:00:00Z")
    XCTAssertNotEqual(
      ReviewBodyTaskKey(item: original, isDaemonOnline: true),
      ReviewBodyTaskKey(item: edited, isDaemonOnline: true),
      "task key must flip when item.updatedAt advances so the body refetches against the new revision"
    )
  }

  func testTaskKeyStableForSameItemAndConnection() {
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")
    let first = ReviewBodyTaskKey(item: item, isDaemonOnline: true)
    let second = ReviewBodyTaskKey(item: item, isDaemonOnline: true)
    XCTAssertEqual(
      first,
      second,
      "task key must stay stable across renders when item and connection are unchanged"
    )
  }

  func testBodyUpdatePublishesDaemonConfirmedBodyAndRefreshesCache() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewBodyUpdate(
      pullRequestID: "PR_1",
      outcome: .updated,
      currentBody: "Edited body",
      currentBodySHA256: String(repeating: "b", count: 64),
      prUpdatedAt: "2026-05-21T01:00:00Z",
      fetchedAt: "2026-05-21T01:01:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.reviewBodies.clear() }

    let response = await store.updateReviewBody(
      pullRequestID: "PR_1",
      expectedPriorBodySHA256: String(repeating: "a", count: 64),
      newBody: "Draft body"
    )

    XCTAssertEqual(response?.outcome, .updated)
    XCTAssertEqual(client.reviewBodyUpdateCallCount(), 1)
    XCTAssertEqual(client.lastReviewBodyUpdateRequest()?.newBody, "Draft body")
    if case .loaded(let body) = store.reviewBodyState["PR_1"] {
      XCTAssertEqual(body, "Edited body")
    } else {
      XCTFail("expected .loaded state with daemon-confirmed body")
    }
    let cached = store.reviewBodies.cached(
      forPullRequestID: "PR_1",
      since: "2026-05-21T01:00:00Z"
    )
    XCTAssertEqual(cached?.body, "Edited body")
    XCTAssertEqual(cached?.fetchedAt, "2026-05-21T01:01:00Z")
  }
}

/// Minimal async semaphore (single-permit) used to suspend a fetch so a
/// second concurrent call can observe the in-flight state.
final class AsyncSemaphore: @unchecked Sendable {
  private let lock = NSLock()
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if signaled {
        signaled = false
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append(continuation)
        lock.unlock()
      }
    }
  }

  func signal() {
    lock.lock()
    if let next = waiters.first {
      waiters.removeFirst()
      lock.unlock()
      next.resume()
    } else {
      signaled = true
      lock.unlock()
    }
  }
}
