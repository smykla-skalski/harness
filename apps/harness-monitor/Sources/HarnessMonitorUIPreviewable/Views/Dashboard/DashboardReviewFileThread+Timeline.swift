import Foundation
import HarnessMonitorKit

extension DashboardReviewFileThreadComment {
  static func timelineComment(
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

  static func timelineComment(
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

extension DashboardReviewFileThread {
  func updatingCollapsed(to collapsed: Bool) -> DashboardReviewFileThread {
    DashboardReviewFileThread(
      id: id,
      path: path,
      side: side,
      line: line,
      diffPosition: diffPosition,
      isResolved: isResolved,
      isCollapsed: collapsed,
      authorLogin: authorLogin,
      comments: comments
    )
  }

  static func timelineThread(
    from payload: ReviewInlineCommentPayload
  ) -> DashboardReviewFileThread? {
    guard !payload.path.isEmpty else { return nil }
    return DashboardReviewFileThread(
      id: payload.id,
      path: payload.path,
      side: nil,
      line: payload.anchorLine().map(Int.init),
      diffPosition: payload.position.map(Int.init),
      isResolved: false,
      isCollapsed: false,
      authorLogin: payload.actor?.login,
      comments: [DashboardReviewFileThreadComment.timelineComment(from: payload)]
    )
  }

  static func timelineThread(
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
      comments: payload.comments.map { DashboardReviewFileThreadComment.timelineComment(from: $0) }
    )
  }

  static func timelineThread(
    fromInlineCommentGroup comments: [ReviewInlineCommentPayload],
    isCollapsed: Bool
  ) -> DashboardReviewFileThread? {
    guard
      let first = comments.sorted(by: DashboardReviewFileThread.inlineCommentSortPredicate).first,
      !first.path.isEmpty
    else {
      return nil
    }
    let orderedComments = comments.sorted(by: DashboardReviewFileThread.inlineCommentSortPredicate)
    return DashboardReviewFileThread(
      id: first.id,
      path: first.path,
      side: nil,
      line: first.anchorLine().map(Int.init),
      diffPosition: first.position.map(Int.init),
      isResolved: false,
      isCollapsed: isCollapsed,
      authorLogin: first.actor?.login,
      comments: orderedComments.map { DashboardReviewFileThreadComment.timelineComment(from: $0) }
    )
  }

  private static func inlineCommentSortPredicate(
    lhs: ReviewInlineCommentPayload,
    rhs: ReviewInlineCommentPayload
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id < rhs.id
  }
}

extension ReviewThreadPayload {
  func anchorLine(side: DashboardReviewFileDiffSide?) -> Int32? {
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

extension ReviewInlineCommentPayload {
  func anchorLine() -> Int32? {
    line ?? originalLine
  }
}
