import Foundation
import HarnessMonitorKit

struct DashboardReviewFileThreadAnchor: Equatable, Identifiable {
  let id: String
  let path: String
  let side: DashboardReviewFileDiffSide?
  let line: Int?
  let diffPosition: Int?
  let commentCount: Int
  let isResolved: Bool
  let authorLogin: String?
  let preview: String
  let url: String?

  var badgeTitle: String {
    if commentCount <= 1 { return "1" }
    return "\(commentCount)"
  }
}

struct DashboardReviewFileThreadIndex: Equatable {
  private let threadsByPath: [String: [DashboardReviewFileThread]]

  init(entries: [ReviewTimelineEntry]) {
    var threads: [String: [DashboardReviewFileThread]] = [:]
    for entry in entries {
      switch entry {
      case .review(let payload):
        for comment in payload.inlineComments {
          Self.append(Self.thread(from: comment), to: &threads)
        }
      case .reviewThread(let payload):
        Self.append(Self.thread(from: payload), to: &threads)
      case .issueComment, .commit, .headRefForcePushed, .simpleActorEvent, .unknown:
        continue
      }
    }
    threadsByPath = threads
  }

  func anchors(forPath path: String) -> [DashboardReviewFileThreadAnchor] {
    threadsByPath[path]?.map(\.anchor) ?? []
  }

  func threads(forPath path: String) -> [DashboardReviewFileThread] {
    threadsByPath[path] ?? []
  }

  func hasUnresolvedAnchors(forPath path: String) -> Bool {
    threadsByPath[path]?.contains { !$0.isResolved } ?? false
  }

  func unresolvedAnchorCount(forPath path: String) -> Int {
    threadsByPath[path]?.reduce(0) { partialResult, thread in
      partialResult + (thread.isResolved ? 0 : 1)
    } ?? 0
  }

  private static func append(
    _ thread: DashboardReviewFileThread?,
    to threads: inout [String: [DashboardReviewFileThread]]
  ) {
    guard let thread else { return }
    threads[thread.path, default: []].append(thread)
  }

  private static func thread(
    from comment: ReviewInlineCommentPayload
  ) -> DashboardReviewFileThread? {
    guard !comment.path.isEmpty else { return nil }
    return DashboardReviewFileThread(
      id: comment.id,
      path: comment.path,
      side: nil,
      line: nil,
      diffPosition: comment.position.map(Int.init),
      isResolved: false,
      isCollapsed: false,
      authorLogin: comment.actor?.login,
      comments: [Self.comment(from: comment)]
    )
  }

  private static func thread(
    from payload: ReviewThreadPayload
  ) -> DashboardReviewFileThread? {
    guard !payload.path.isEmpty else { return nil }
    let side = DashboardReviewFileDiffSide(wireValue: payload.diffSide)
    return DashboardReviewFileThread(
      id: payload.id,
      path: payload.path,
      side: side,
      line: payload.anchorLine(side: side).map(Int.init),
      diffPosition: nil,
      isResolved: payload.isResolved,
      isCollapsed: payload.isCollapsed,
      authorLogin: payload.actor?.login ?? payload.comments.first?.actor?.login,
      comments: payload.comments.map { Self.comment(from: $0) }
    )
  }

  private static func comment(
    from payload: ReviewThreadCommentPayload
  ) -> DashboardReviewFileThreadComment {
    DashboardReviewFileThreadComment(
      id: payload.id,
      authorLogin: payload.actor?.login,
      authorAvatarURL: payload.actor?.avatarURL,
      body: payload.body,
      createdAt: payload.createdAt,
      url: payload.url
    )
  }

  private static func comment(
    from payload: ReviewInlineCommentPayload
  ) -> DashboardReviewFileThreadComment {
    DashboardReviewFileThreadComment(
      id: payload.id,
      authorLogin: payload.actor?.login,
      authorAvatarURL: payload.actor?.avatarURL,
      body: payload.body,
      createdAt: payload.createdAt,
      url: payload.url
    )
  }
}

@MainActor
final class DashboardReviewFileThreadIndexCache {
  private var cachedRevision: UInt64?
  private var cachedIndex = DashboardReviewFileThreadIndex(entries: [])

  func index(for timeline: ReviewTimelineViewModel) -> DashboardReviewFileThreadIndex {
    let revision = timeline.revision
    guard cachedRevision != revision else { return cachedIndex }
    cachedRevision = revision
    cachedIndex = DashboardReviewFileThreadIndex(entries: timeline.entries)
    return cachedIndex
  }
}

extension ReviewThreadPayload {
  fileprivate func anchorLine(side: DashboardReviewFileDiffSide?) -> Int32? {
    switch side {
    case .old:
      originalLine ?? line
    case .new:
      line ?? originalLine
    case nil:
      line ?? originalLine
    }
  }
}

extension String {
  var anchorPreview: String {
    let collapsed = split(whereSeparator: { $0.isNewline }).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.count <= 96 { return collapsed }
    return "\(collapsed.prefix(93))..."
  }
}
