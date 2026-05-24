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
  private let anchorsByPath: [String: [DashboardReviewFileThreadAnchor]]

  init(entries: [ReviewTimelineEntry]) {
    var anchors: [String: [DashboardReviewFileThreadAnchor]] = [:]
    for entry in entries {
      switch entry {
      case .review(let payload):
        for comment in payload.inlineComments {
          Self.append(Self.anchor(from: comment), to: &anchors)
        }
      case .reviewThread(let payload):
        Self.append(Self.anchor(from: payload), to: &anchors)
      case .issueComment, .commit, .headRefForcePushed, .simpleActorEvent, .unknown:
        continue
      }
    }
    anchorsByPath = anchors
  }

  func anchors(forPath path: String) -> [DashboardReviewFileThreadAnchor] {
    anchorsByPath[path] ?? []
  }

  func hasUnresolvedAnchors(forPath path: String) -> Bool {
    anchorsByPath[path]?.contains { !$0.isResolved } ?? false
  }

  func unresolvedAnchorCount(forPath path: String) -> Int {
    anchorsByPath[path]?.reduce(0) { partialResult, anchor in
      partialResult + (anchor.isResolved ? 0 : 1)
    } ?? 0
  }

  private static func append(
    _ anchor: DashboardReviewFileThreadAnchor?,
    to anchors: inout [String: [DashboardReviewFileThreadAnchor]]
  ) {
    guard let anchor else { return }
    anchors[anchor.path, default: []].append(anchor)
  }

  private static func anchor(
    from comment: ReviewInlineCommentPayload
  ) -> DashboardReviewFileThreadAnchor? {
    guard !comment.path.isEmpty else { return nil }
    return DashboardReviewFileThreadAnchor(
      id: comment.id,
      path: comment.path,
      side: nil,
      line: nil,
      diffPosition: comment.position.map(Int.init),
      commentCount: 1,
      isResolved: false,
      authorLogin: comment.actor?.login,
      preview: comment.bodyTextForAnchor,
      url: comment.url
    )
  }

  private static func anchor(from thread: ReviewThreadPayload) -> DashboardReviewFileThreadAnchor? {
    guard !thread.path.isEmpty else { return nil }
    let side = DashboardReviewFileDiffSide(wireValue: thread.diffSide)
    return DashboardReviewFileThreadAnchor(
      id: thread.id,
      path: thread.path,
      side: side,
      line: thread.anchorLine(side: side).map(Int.init),
      diffPosition: nil,
      commentCount: max(thread.comments.count, 1),
      isResolved: thread.isResolved,
      authorLogin: thread.actor?.login ?? thread.comments.first?.actor?.login,
      preview: thread.comments.first?.body.anchorPreview ?? "",
      url: thread.comments.first?.url
    )
  }
}

extension ReviewInlineCommentPayload {
  fileprivate var bodyTextForAnchor: String {
    body.anchorPreview
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
  fileprivate var anchorPreview: String {
    let collapsed = split(whereSeparator: { $0.isNewline }).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if collapsed.count <= 96 { return collapsed }
    return "\(collapsed.prefix(93))..."
  }
}
