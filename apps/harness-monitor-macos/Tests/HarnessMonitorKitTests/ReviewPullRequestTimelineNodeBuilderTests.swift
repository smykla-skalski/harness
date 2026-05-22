import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class DependencyPullRequestTimelineNodeBuilderTests: XCTestCase {
  func testHeavyReviewThreadAutoCollapseSuppressesChildRows() {
    let thread = DependencyUpdateTimelineEntry.reviewThread(
      ReviewThreadPayload(
        id: "thread-1",
        createdAt: "2026-05-22T11:00:00Z",
        path: "Sources/App.swift",
        line: 42,
        comments: (0..<7).map { index in
          ReviewThreadCommentPayload(
            id: "comment-\(index)",
            body: "Comment \(index)",
            createdAt: "2026-05-22T11:00:00Z"
          )
        }
      )
    )

    let collapsed = DependencyPullRequestTimelineNodeBuilder().buildNodes(
      for: [thread],
      pullRequestID: "PR_1",
      autoCollapseHeavyReviewThreads: true,
      configuration: .default
    )
    let expanded = DependencyPullRequestTimelineNodeBuilder().buildNodes(
      for: [thread],
      pullRequestID: "PR_1",
      autoCollapseHeavyReviewThreads: false,
      configuration: .default
    )

    XCTAssertEqual(collapsed.count, 1)
    XCTAssertEqual(collapsed.first?.statusBadgeLabel, "7 comments")
    XCTAssertEqual(expanded.count, 8)
  }
}
