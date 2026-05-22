import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreDependencyTimelineRefreshTests: XCTestCase {
  private func makeStore() throws -> HarnessMonitorStore {
    let harness = try PersistenceIntegrationTestHarness()
    return HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: RecordingHarnessClient()),
      voiceCapture: NativeVoiceCaptureService(),
      modelContainer: harness.container
    )
  }

  private func issueComment(id: String) -> DependencyUpdateTimelineEntry {
    .issueComment(IssueCommentPayload(id: id, createdAt: "2026-05-22T10:00:00Z", body: ""))
  }

  private func samplePage(
    pullRequestID: String,
    entries: [DependencyUpdateTimelineEntry]
  ) -> DependencyUpdatesTimelineResponse {
    DependencyUpdatesTimelineResponse(
      pullRequestId: pullRequestID,
      entries: entries,
      pageInfo: DependencyUpdateTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2026-05-22T15:00:00Z"
    )
  }

  func testInvalidateClearsAffectedTimelinesOnly() async throws {
    let store = try makeStore()
    let alpha = store.dependencyUpdateTimelineViewModel(for: "PR_alpha")
    alpha.apply(initial: samplePage(pullRequestID: "PR_alpha", entries: [issueComment(id: "a1")]))
    let beta = store.dependencyUpdateTimelineViewModel(for: "PR_beta")
    beta.apply(initial: samplePage(pullRequestID: "PR_beta", entries: [issueComment(id: "b1")]))

    store.invalidateDependencyUpdateTimelines(for: ["PR_alpha"])

    XCTAssertTrue(alpha.entries.isEmpty, "alpha timeline should be cleared")
    XCTAssertEqual(beta.entries.count, 1, "beta timeline should be untouched")
  }

  func testInvalidateMissingPRsIsANoOp() async throws {
    let store = try makeStore()
    store.invalidateDependencyUpdateTimelines(for: ["PR_never_visited"])
    // Resolving the view model AFTER the invalidate creates a fresh,
    // empty one — proving the invalidate didn't poison anything.
    let viewModel = store.dependencyUpdateTimelineViewModel(for: "PR_never_visited")
    XCTAssertTrue(viewModel.entries.isEmpty)
  }
}
