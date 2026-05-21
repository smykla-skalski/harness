import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreDependencyBodyTests: XCTestCase {
  private func makeItem(
    pullRequestID: String = "PR_1",
    updatedAt: String = "2026-05-21T00:00:00Z"
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
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
    store.dependencyUpdateBodies.clear()
    return store
  }

  func testCacheMissTriggersFetchAndPublishesLoaded() async throws {
    let client = RecordingHarnessClient()
    client.configureDependencyBody(
      pullRequestID: "PR_1",
      body: "Hello world",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.dependencyUpdateBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    await store.prepareDependencyUpdateBody(for: item)

    XCTAssertEqual(client.dependencyBodyFetchCount(), 1)
    if case .loaded(let body) = store.dependencyUpdateBodyState["PR_1"] {
      XCTAssertEqual(body, "Hello world")
    } else {
      XCTFail("expected .loaded state")
    }
  }

  func testCacheHitSkipsClient() async throws {
    let client = RecordingHarnessClient()
    client.configureDependencyBody(
      pullRequestID: "PR_1",
      body: "First",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.dependencyUpdateBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    await store.prepareDependencyUpdateBody(for: item)
    XCTAssertEqual(client.dependencyBodyFetchCount(), 1)

    await store.prepareDependencyUpdateBody(for: item)
    XCTAssertEqual(client.dependencyBodyFetchCount(), 1, "Cache hit must skip client")
    if case .loaded(let body) = store.dependencyUpdateBodyState["PR_1"] {
      XCTAssertEqual(body, "First")
    } else {
      XCTFail("expected .loaded state")
    }
  }

  func testUpdatedAtAdvanceTriggersRefetch() async throws {
    let client = RecordingHarnessClient()
    client.configureDependencyBody(
      pullRequestID: "PR_1",
      body: "Old",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let store = try makeStore(client: client)
    defer { store.dependencyUpdateBodies.clear() }
    let stale = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")
    await store.prepareDependencyUpdateBody(for: stale)
    XCTAssertEqual(client.dependencyBodyFetchCount(), 1)

    client.configureDependencyBody(
      pullRequestID: "PR_1",
      body: "Fresh",
      prUpdatedAt: "2026-05-21T00:30:00Z"
    )
    let fresh = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:30:00Z")
    await store.prepareDependencyUpdateBody(for: fresh)

    XCTAssertEqual(client.dependencyBodyFetchCount(), 2, "Advanced updatedAt must invalidate cache")
    if case .loaded(let body) = store.dependencyUpdateBodyState["PR_1"] {
      XCTAssertEqual(body, "Fresh")
    } else {
      XCTFail("expected .loaded state with fresh body")
    }
  }

  func testConcurrentFetchesDedupe() async throws {
    let client = RecordingHarnessClient()
    client.configureDependencyBody(
      pullRequestID: "PR_1",
      body: "Body",
      prUpdatedAt: "2026-05-21T00:00:00Z"
    )
    let gate = AsyncSemaphore()
    client.setDependencyBodyFetchHook { _ in await gate.wait() }

    let store = try makeStore(client: client)
    defer { store.dependencyUpdateBodies.clear() }
    let item = makeItem(pullRequestID: "PR_1", updatedAt: "2026-05-21T00:00:00Z")

    async let first: () = store.prepareDependencyUpdateBody(for: item)
    await Task.yield()
    await Task.yield()
    async let second: () = store.prepareDependencyUpdateBody(for: item)
    await Task.yield()
    await Task.yield()

    gate.signal()
    _ = await (first, second)

    XCTAssertEqual(
      client.dependencyBodyFetchCount(),
      1,
      "concurrent prepare calls must collapse to one client fetch"
    )
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
