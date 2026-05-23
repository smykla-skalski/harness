import SwiftData
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

  func testHeavyReviewThreadAutoCollapseSuppressesChildRows() {
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
    XCTAssertEqual(collapsed.first?.statusBadgeLabel, "7 comments")
    XCTAssertEqual(expanded.count, 8)
  }

  func testAvatarCachePersistsDaemonFetchedBytesInSwiftData() async throws {
    let avatarURL = try XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/in/2740?v=4"))
    let modelContainer = try HarnessMonitorModelContainer.preview()
    let client = AvatarProbeClient(
      response: ReviewsAvatarResponse(
        avatarURL: avatarURL.absoluteString,
        mimeType: "image/png",
        contentBase64: Self.onePixelPNGBase64,
        fetchedAt: "2026-05-22T10:00:00Z"
      )
    )
    await ReviewAvatarCache.shared.clear()

    let first = await ReviewAvatarCache.shared.avatar(
      for: avatarURL,
      targetPixel: 36,
      modelContainer: modelContainer,
      client: client
    )
    await ReviewAvatarCache.shared.clear()
    let second = await ReviewAvatarCache.shared.avatar(
      for: avatarURL,
      targetPixel: 36,
      modelContainer: modelContainer,
      client: client
    )

    XCTAssertNotNil(first)
    XCTAssertNotNil(second)
    let calls = await client.callCount()
    XCTAssertEqual(calls, 1)
    let context = ModelContext(modelContainer)
    let rows = try context.fetch(FetchDescriptor<CachedReviewAvatar>())
    XCTAssertEqual(rows.map(\.avatarURL), [avatarURL.absoluteString])
    XCTAssertEqual(rows.first?.mimeType, "image/png")
  }

  func testFallbackAvatarURLStillRoutesThroughGitHub() {
    let fallback = ReviewAvatarCache.fallbackAvatarURL(login: "renovate[bot]")

    XCTAssertEqual(fallback?.absoluteString, "https://github.com/renovate%5Bbot%5D.png?size=64")
  }

  private static let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}

private actor AvatarProbeClient: HarnessMonitorReviewsClientProtocol {
  private(set) var calls = 0
  private let response: ReviewsAvatarResponse

  init(response: ReviewsAvatarResponse) {
    self.response = response
  }

  func fetchReviewAvatar(
    request _: ReviewsAvatarRequest
  ) async throws -> ReviewsAvatarResponse {
    calls += 1
    return response
  }

  func callCount() -> Int {
    calls
  }
}
