import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreReviewTimelineTests: XCTestCase {
  private func makeItem(pullRequestID: String = "PR_t1") -> ReviewItem {
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
      updatedAt: "2026-05-21T00:00:00Z"
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
    return store
  }

  private func samplePage(
    pullRequestID: String,
    entries: [ReviewTimelineEntry],
    startCursor: String? = nil,
    hasOlder: Bool = false
  ) -> ReviewsTimelineResponse {
    ReviewsTimelineResponse(
      pullRequestId: pullRequestID,
      entries: entries,
      pageInfo: ReviewTimelinePageInfo(
        startCursor: startCursor,
        endCursor: "end",
        hasOlder: hasOlder,
        hasNewer: false
      ),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T00:00:00Z"
    )
  }

  private func comment(id: String, body: String) -> ReviewTimelineEntry {
    .issueComment(IssueCommentPayload(id: id, createdAt: "2026-05-22T10:00:00Z", body: body))
  }

  func testPrepareFetchesAndPopulatesViewModel() async throws {
    let client = RecordingHarnessClient()
    client.enqueueReviewTimelineResponse(
      samplePage(
        pullRequestID: "PR_t1",
        entries: [comment(id: "IC_1", body: "first")],
        startCursor: "s1",
        hasOlder: true
      )
    )
    let store = try makeStore(client: client)

    await store.prepareReviewTimeline(for: makeItem(), pageSize: 30)

    XCTAssertEqual(client.reviewTimelineFetchCount(), 1)
    XCTAssertEqual(client.reviewTimelineRequestedPageSizes(for: "PR_t1"), [30])
    let vm = store.reviewTimelineViewModel(for: "PR_t1")
    XCTAssertEqual(vm.entries.map(\.id), ["IC_1"])
    XCTAssertTrue(vm.hasOlder)
    XCTAssertEqual(vm.startCursor, "s1")
    XCTAssertEqual(vm.loadState, .idle)
  }

  func testPrepareIsIdempotentForCachedEntries() async throws {
    let client = RecordingHarnessClient()
    client.enqueueReviewTimelineResponse(
      samplePage(pullRequestID: "PR_t1", entries: [comment(id: "IC_1", body: "first")])
    )
    let store = try makeStore(client: client)
    await store.prepareReviewTimeline(for: makeItem())
    XCTAssertEqual(client.reviewTimelineFetchCount(), 1)

    await store.prepareReviewTimeline(for: makeItem())
    XCTAssertEqual(
      client.reviewTimelineFetchCount(),
      1,
      "second call should short-circuit on populated view model"
    )
  }

  func testForceRefreshRefetches() async throws {
    let client = RecordingHarnessClient()
    client.enqueueReviewTimelineResponse(
      samplePage(pullRequestID: "PR_t1", entries: [comment(id: "IC_1", body: "first")])
    )
    client.enqueueReviewTimelineResponse(
      samplePage(pullRequestID: "PR_t1", entries: [comment(id: "IC_2", body: "second")])
    )
    let store = try makeStore(client: client)
    await store.prepareReviewTimeline(for: makeItem())
    await store.prepareReviewTimeline(for: makeItem(), forceRefresh: true)

    XCTAssertEqual(client.reviewTimelineFetchCount(), 2)
    let vm = store.reviewTimelineViewModel(for: "PR_t1")
    XCTAssertEqual(vm.entries.map(\.id), ["IC_2"])
  }

  func testConcurrentPreparesCollapseToSingleFetch() async throws {
    let client = RecordingHarnessClient()
    client.enqueueReviewTimelineResponse(
      samplePage(pullRequestID: "PR_t1", entries: [comment(id: "IC_1", body: "first")])
    )
    let gate = AsyncGate()
    client.setReviewTimelineFetchHook { _ in await gate.wait() }
    let store = try makeStore(client: client)
    let item = makeItem()

    async let first: () = store.prepareReviewTimeline(for: item)
    async let second: () = store.prepareReviewTimeline(for: item)
    try await Task.sleep(nanoseconds: 20_000_000)
    await gate.open()
    _ = await (first, second)

    XCTAssertEqual(
      client.reviewTimelineFetchCount(),
      1,
      "second concurrent call should dedupe on pending key"
    )
  }

  func testLoadOlderAdvancesCursor() async throws {
    let client = RecordingHarnessClient()
    client.enqueueReviewTimelineResponse(
      samplePage(
        pullRequestID: "PR_t1",
        entries: [comment(id: "IC_2", body: "second")],
        startCursor: "s1",
        hasOlder: true
      )
    )
    client.enqueueReviewTimelineResponse(
      samplePage(
        pullRequestID: "PR_t1",
        entries: [comment(id: "IC_1", body: "first")],
        startCursor: "s0",
        hasOlder: false
      )
    )
    let store = try makeStore(client: client)
    await store.prepareReviewTimeline(for: makeItem())
    await store.loadOlderReviewTimeline(for: makeItem(), pageSize: 20)

    XCTAssertEqual(client.reviewTimelineFetchCount(), 2)
    let cursors = client.reviewTimelineRequestedCursors(for: "PR_t1")
    XCTAssertEqual(cursors, [nil, "s1"])
    XCTAssertEqual(client.reviewTimelineRequestedPageSizes(for: "PR_t1"), [50, 20])
    let vm = store.reviewTimelineViewModel(for: "PR_t1")
    XCTAssertEqual(vm.entries.map(\.id), ["IC_1", "IC_2"])
    XCTAssertFalse(vm.hasOlder)
  }

  func testFailureSurfacesInViewModel() async throws {
    let client = RecordingHarnessClient()
    struct Boom: Error, LocalizedError {
      var errorDescription: String? { "boom" }
    }
    client.configureReviewTimelineError(pullRequestID: "PR_t1", error: Boom())
    let store = try makeStore(client: client)

    await store.prepareReviewTimeline(for: makeItem())

    let vm = store.reviewTimelineViewModel(for: "PR_t1")
    XCTAssertEqual(vm.loadState, .failed)
    XCTAssertEqual(vm.lastError, "boom")
    XCTAssertTrue(vm.entries.isEmpty)
  }
}

private actor AsyncGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let waiters = continuations
    continuations.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
