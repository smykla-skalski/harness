import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension ReviewPullRequestTimelineNodeBuilderTests {
  static func fullContentSheetEntries() -> [ReviewTimelineEntry] {
    [
      .issueComment(
        IssueCommentPayload(
          id: "issue-1",
          createdAt: "2026-05-22T09:00:00Z",
          body: "Issue body"
        )
      ),
      .issueComment(
        IssueCommentPayload(
          id: "issue-hidden",
          createdAt: "2026-05-22T09:01:00Z",
          body: "Hidden body",
          isMinimized: true
        )
      ),
      .review(
        ReviewPayload(
          id: "review-1",
          createdAt: "2026-05-22T09:02:00Z",
          state: .commented,
          body: "Review body",
          inlineComments: [
            ReviewInlineCommentPayload(
              id: "inline-1",
              path: "Sources/App.swift",
              line: 18,
              diffHunk: "@@ -17,2 +17,3 @@\n context\n+inline line\n context",
              body: "Inline body",
              createdAt: "2026-05-22T09:03:00Z"
            )
          ]
        )
      ),
      .reviewThread(
        ReviewThreadPayload(
          id: "thread-1",
          createdAt: "2026-05-22T09:04:00Z",
          path: "Sources/App.swift",
          line: 42,
          diffSide: "RIGHT",
          diffHunk: "@@ -41,2 +41,3 @@\n context\n+thread line\n context",
          comments: [
            ReviewThreadCommentPayload(
              id: "thread-comment-1",
              body: "Thread body",
              createdAt: "2026-05-22T09:05:00Z"
            )
          ]
        )
      ),
      .commit(
        CommitPayload(
          id: "commit-1",
          createdAt: "2026-05-22T09:06:00Z",
          oid: "d2d8d55abcdef",
          abbreviatedOid: "d2d8d55",
          messageHeadline: "Commit headline"
        )
      ),
    ]
  }
}
