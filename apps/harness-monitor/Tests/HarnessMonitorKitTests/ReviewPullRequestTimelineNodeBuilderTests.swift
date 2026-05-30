import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class ReviewPullRequestTimelineNodeBuilderTests: XCTestCase {
  func testTimelineNodesPreserveActorAvatarURLs() throws {
    let renovateAvatar = try XCTUnwrap(
      URL(string: "https://avatars.githubusercontent.com/in/2740?v=4")
    )
    let reviewerAvatar = try XCTUnwrap(
      URL(string: "https://avatars.githubusercontent.com/u/11655498?v=4")
    )
    let entries: [ReviewTimelineEntry] = [
      .simpleActorEvent(
        SimpleActorEventPayload(
          id: "label-1",
          createdAt: "2026-05-22T10:00:00Z",
          actor: ReviewTimelineActor(login: "renovate", avatarURL: renovateAvatar),
          eventKind: .labeled,
          label: "dependencies"
        )
      ),
      .commit(
        CommitPayload(
          id: "commit-1",
          createdAt: "2026-05-22T10:01:00Z",
          actor: ReviewTimelineActor(login: "renovate[bot]", avatarURL: renovateAvatar),
          oid: "d2d8d55abcdef",
          abbreviatedOid: "d2d8d55",
          messageHeadline: "Update dependency",
          authorLogin: "renovate[bot]"
        )
      ),
      .review(
        ReviewPayload(
          id: "review-1",
          createdAt: "2026-05-22T10:02:00Z",
          actor: ReviewTimelineActor(login: "bartsmykla", avatarURL: reviewerAvatar),
          state: .approved
        )
      ),
    ]

    let nodes = ReviewPullRequestTimelineNodeBuilder().buildNodes(
      for: entries,
      pullRequestID: "PR_1",
      configuration: .default
    )

    XCTAssertEqual(nodes.map(\.actorAvatarURL), [renovateAvatar, renovateAvatar, reviewerAvatar])
    XCTAssertEqual(nodes.map(\.actorLogin), ["renovate", "renovate[bot]", "bartsmykla"])
  }

  func testHeavyReviewThreadAutoCollapseCollapsesConversationCard() {
    let thread = ReviewTimelineEntry.reviewThread(
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

    let collapsed = ReviewPullRequestTimelineNodeBuilder().buildNodes(
      for: [thread],
      pullRequestID: "PR_1",
      autoCollapseHeavyReviewThreads: true,
      configuration: .default
    )
    let expanded = ReviewPullRequestTimelineNodeBuilder().buildNodes(
      for: [thread],
      pullRequestID: "PR_1",
      autoCollapseHeavyReviewThreads: false,
      configuration: .default
    )

    XCTAssertEqual(collapsed.count, 1)
    XCTAssertEqual(expanded.count, 1)
    XCTAssertEqual(collapsed.first?.reviewInlineConversation?.thread.isCollapsed, true)
    XCTAssertEqual(expanded.first?.reviewInlineConversation?.thread.isCollapsed, false)
  }

  func testReviewTimelinePrefersReviewThreadEntriesOverDuplicateInlineGroups() {
    let entries: [ReviewTimelineEntry] = [
      .review(
        ReviewPayload(
          id: "review-1",
          createdAt: "2026-05-22T09:02:00Z",
          state: .commented,
          inlineComments: [
            ReviewInlineCommentPayload(
              id: "inline-1",
              path: "Sources/App.swift",
              line: 18,
              diffHunk: "@@ -17,2 +17,3 @@\n context\n+inline line\n context",
              body: "Inline body",
              createdAt: "2026-05-22T09:03:00Z",
              actor: ReviewTimelineActor(login: "reviewer")
            )
          ]
        )
      ),
      .reviewThread(
        ReviewThreadPayload(
          id: "thread-1",
          createdAt: "2026-05-22T09:04:00Z",
          path: "Sources/App.swift",
          line: 18,
          diffSide: "RIGHT",
          diffHunk: "@@ -17,2 +17,3 @@\n context\n+thread line\n context",
          comments: [
            ReviewThreadCommentPayload(
              id: "thread-comment-1",
              body: "Inline body",
              createdAt: "2026-05-22T09:03:00Z",
              actor: ReviewTimelineActor(login: "reviewer")
            ),
            ReviewThreadCommentPayload(
              id: "thread-comment-2",
              body: "Reply body",
              createdAt: "2026-05-22T09:06:00Z",
              actor: ReviewTimelineActor(login: "maintainer")
            ),
          ]
        )
      ),
    ]

    let nodes = ReviewPullRequestTimelineNodeBuilder().buildNodes(
      for: entries,
      pullRequestID: "PR_1",
      configuration: .default
    )

    XCTAssertEqual(nodes.count, 2)
    let inlineConversationNodes = nodes.compactMap(\.reviewInlineConversation)
    XCTAssertEqual(inlineConversationNodes.count, 1)
    XCTAssertEqual(nodes.last?.identity, .entry("thread-1"))
    XCTAssertEqual(
      inlineConversationNodes.first?.thread.comments.map(\.id),
      [
        "thread-comment-1",
        "thread-comment-2",
      ])
  }

  func testInlineConversationRowsRenderInlineInsteadOfUsingFullContentSheet() throws {
    let entries: [ReviewTimelineEntry] = [
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

    let nodes = ReviewPullRequestTimelineNodeBuilder().buildNodes(
      for: entries,
      pullRequestID: "PR_1",
      configuration: .default
    )

    let issueNode = try XCTUnwrap(nodes.first { $0.identity == .entry("issue-1") })
    let hiddenIssueNode = try XCTUnwrap(nodes.first { $0.identity == .entry("issue-hidden") })
    let reviewNode = try XCTUnwrap(nodes.first { $0.identity == .entry("review-1") })
    let inlineConversationNode = try XCTUnwrap(
      nodes.first { $0.identity == .entry("review-1:inline-1") }
    )
    let threadNode = try XCTUnwrap(nodes.first { $0.identity == .entry("thread-1") })
    let commitNode = try XCTUnwrap(nodes.first { $0.identity == .entry("commit-1") })

    XCTAssertTrue(issueNode.canOpenFullContent)
    XCTAssertFalse(hiddenIssueNode.canOpenFullContent)
    XCTAssertTrue(reviewNode.canOpenFullContent)
    XCTAssertFalse(inlineConversationNode.canOpenFullContent)
    XCTAssertNotNil(inlineConversationNode.reviewInlineConversation)
    XCTAssertFalse(threadNode.canOpenFullContent)
    XCTAssertNotNil(threadNode.reviewInlineConversation)
    XCTAssertTrue(commitNode.canOpenFullContent)

    XCTAssertEqual(
      DashboardReviewConversationFullContentResolver.resolve(node: issueNode, entries: entries)?
        .markdown,
      "Issue body"
    )
    XCTAssertNil(
      DashboardReviewConversationFullContentResolver.resolve(
        node: hiddenIssueNode,
        entries: entries
      )
    )
    XCTAssertEqual(
      DashboardReviewConversationFullContentResolver.resolve(node: reviewNode, entries: entries)?
        .markdown,
      "Review body"
    )
    XCTAssertNil(
      DashboardReviewConversationFullContentResolver.resolve(
        node: inlineConversationNode,
        entries: entries
      )
    )
    XCTAssertNil(
      DashboardReviewConversationFullContentResolver.resolve(node: threadNode, entries: entries)
    )
    XCTAssertEqual(
      DashboardReviewConversationFullContentResolver.resolve(node: commitNode, entries: entries)?
        .markdown,
      "Commit headline"
    )
  }

  func testFallbackAvatarURLStillRoutesThroughGitHub() {
    let fallback = ReviewAvatarCache.fallbackAvatarURL(login: "renovate[bot]")

    XCTAssertEqual(fallback?.absoluteString, "https://github.com/renovate%5Bbot%5D.png?size=64")
  }
}
