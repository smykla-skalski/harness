import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreReviewCommentTests: XCTestCase {
  private func makeItem(pullRequestID: String = "PR_c1") -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: "repo_1",
      repository: "acme/api",
      number: 7,
      title: "chore(deps): bump bar",
      url: "https://example.com",
      authorLogin: "renovate[bot]",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "head_sha",
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

  func testEmptyBodyShortCircuits() async throws {
    let store = try makeStore(client: RecordingHarnessClient())
    let outcome = await store.postReviewComment(for: makeItem(), body: "   ")
    XCTAssertEqual(outcome, .empty)
  }

  func testNoClientReturnsDaemonOffline() async throws {
    let store = try makeStore(client: RecordingHarnessClient())
    store.client = nil
    let outcome = await store.postReviewComment(for: makeItem(), body: "hello")
    XCTAssertEqual(outcome, .daemonOffline)
    let viewModel = store.reviewTimelineViewModel(for: "PR_c1")
    XCTAssertTrue(
      viewModel.entries.isEmpty,
      "no optimistic entry should land when there is no client to deliver it"
    )
  }

  func testDaemonFailureRemovesOptimisticAndSurfacesReason() async throws {
    // RecordingHarnessClient does not override commentReviews, so
    // the protocol default throws `HarnessMonitorAPIError.server(501, "Reviews unavailable")`.
    // The optimistic entry appended before the call must be reverted on the thrown
    // error and the outcome carry the readable reason.
    let store = try makeStore(client: RecordingHarnessClient())
    let viewModel = store.reviewTimelineViewModel(for: "PR_c1")

    let outcome = await store.postReviewComment(
      for: makeItem(),
      body: "ship it",
      viewerLogin: "alice"
    )

    if case .failed(let reason) = outcome {
      XCTAssertFalse(reason.isEmpty, "failure outcome should carry a reason")
    } else {
      XCTFail("expected .failed outcome, got \(outcome)")
    }
    XCTAssertTrue(
      viewModel.entries.isEmpty,
      "optimistic entry must be reverted when the comment post fails"
    )
  }

  func testSuccessReplacesOptimisticEntryWithGitHubEntry() async throws {
    let client = RecordingHarnessClient()
    let landedEntry = ReviewTimelineEntry.issueComment(
      IssueCommentPayload(
        id: "IC_landed",
        createdAt: "2026-05-22T11:00:00Z",
        actor: ReviewTimelineActor(login: "alice"),
        body: "ship it",
        viewerDidAuthor: true,
        viewerCanEdit: true
      )
    )
    client.configureReviewCommentResponse(
      ReviewsActionResponse(
        summary: "Posted dependency update comment: 1 applied, 0 skipped, 0 failed",
        results: [
          ReviewActionResult(
            repository: "acme/api",
            number: 7,
            action: .comment,
            outcome: .applied,
            timelineEntry: landedEntry
          )
        ]
      )
    )
    let store = try makeStore(client: client)
    let viewModel = store.reviewTimelineViewModel(for: "PR_c1")

    let outcome = await store.postReviewComment(
      for: makeItem(),
      body: "ship it",
      viewerLogin: "alice"
    )

    if case .posted = outcome {
      XCTAssertEqual(viewModel.entries.map(\.id), ["IC_landed"])
    } else {
      XCTFail("expected .posted outcome, got \(outcome)")
    }
  }
}
