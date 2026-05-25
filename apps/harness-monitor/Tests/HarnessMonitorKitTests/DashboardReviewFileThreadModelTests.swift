import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file thread model")
struct DashboardReviewFileThreadModelTests {
  @Test("index builds a rich thread carrying every comment in order")
  func indexBuildsRichThreadCarryingEveryComment() {
    let path = "Sources/Feature.swift"
    let index = DashboardReviewFileThreadIndex(entries: [
      .reviewThread(
        ReviewThreadPayload(
          id: "thread-1",
          createdAt: "2026-05-25T09:00:00Z",
          actor: ReviewTimelineActor(login: "octocat"),
          isResolved: false,
          isCollapsed: false,
          path: path,
          line: 42,
          diffSide: "RIGHT",
          comments: [
            ReviewThreadCommentPayload(
              id: "c1",
              body: "First note",
              createdAt: "2026-05-25T09:00:00Z",
              actor: ReviewTimelineActor(
                login: "octocat",
                avatarURL: URL(string: "https://example.test/a.png")
              ),
              url: "https://github.test/c1"
            ),
            ReviewThreadCommentPayload(
              id: "c2",
              body: "Reply note",
              createdAt: "2026-05-25T09:05:00Z",
              actor: ReviewTimelineActor(login: "hubber"),
              url: "https://github.test/c2"
            ),
          ]
        )
      )
    ])

    let threads = index.threads(forPath: path)
    #expect(threads.count == 1)
    #expect(threads.first?.id == "thread-1")
    #expect(threads.first?.isResolved == false)
    #expect(threads.first?.line == 42)
    #expect(threads.first?.side == .new)
    #expect(threads.first?.comments.map(\.id) == ["c1", "c2"])
    #expect(threads.first?.comments.map(\.body) == ["First note", "Reply note"])
    #expect(threads.first?.comments.first?.authorLogin == "octocat")
    #expect(
      threads.first?.comments.first?.authorAvatarURL == URL(string: "https://example.test/a.png")
    )
    #expect(threads.first?.comments.last?.authorLogin == "hubber")
    #expect(threads.first?.comments.first?.url == "https://github.test/c1")
  }

  @Test("index maps an inline review comment to a single-comment thread")
  func indexMapsInlineReviewCommentToSingleCommentThread() {
    let path = "Sources/Other.swift"
    let index = DashboardReviewFileThreadIndex(entries: [
      .review(
        ReviewPayload(
          id: "review-1",
          createdAt: "2026-05-25T08:00:00Z",
          state: .commented,
          inlineComments: [
            ReviewInlineCommentPayload(
              id: "inline-1",
              path: path,
              position: 7,
              body: "Inline remark",
              createdAt: "2026-05-25T08:00:00Z",
              actor: ReviewTimelineActor(login: "reviewer")
            )
          ]
        )
      )
    ])

    let threads = index.threads(forPath: path)
    #expect(threads.count == 1)
    #expect(threads.first?.id == "inline-1")
    #expect(threads.first?.diffPosition == 7)
    #expect(threads.first?.side == nil)
    #expect(threads.first?.line == nil)
    #expect(threads.first?.isResolved == false)
    #expect(threads.first?.comments.count == 1)
    #expect(threads.first?.comments.first?.body == "Inline remark")
    #expect(threads.first?.comments.first?.authorLogin == "reviewer")
  }

  @Test("rich thread derives an anchor summary and maps resolved state")
  func richThreadDerivesAnchorSummaryAndMapsResolvedState() {
    let path = "Sources/Resolved.swift"
    let index = DashboardReviewFileThreadIndex(entries: [
      .reviewThread(
        ReviewThreadPayload(
          id: "thread-resolved",
          createdAt: "2026-05-25T07:00:00Z",
          isResolved: true,
          path: path,
          line: 10,
          diffSide: "LEFT",
          comments: [
            ReviewThreadCommentPayload(
              id: "rc1",
              body: "Looks good now",
              createdAt: "2026-05-25T07:00:00Z",
              actor: ReviewTimelineActor(login: "maintainer"),
              url: "https://github.test/rc1"
            )
          ]
        )
      )
    ])

    let threads = index.threads(forPath: path)
    #expect(threads.first?.isResolved == true)
    #expect(threads.first?.side == .old)

    let anchor = threads.first?.anchor
    #expect(anchor?.id == "thread-resolved")
    #expect(anchor?.isResolved == true)
    #expect(anchor?.commentCount == 1)
    #expect(anchor?.authorLogin == "maintainer")
    #expect(anchor?.preview == "Looks good now")
    #expect(anchor?.url == "https://github.test/rc1")

    // Anchor-derived helpers keep their existing contract.
    #expect(index.anchors(forPath: path).map(\.id) == ["thread-resolved"])
    #expect(!index.hasUnresolvedAnchors(forPath: path))
    #expect(index.unresolvedAnchorCount(forPath: path) == 0)
  }
}
