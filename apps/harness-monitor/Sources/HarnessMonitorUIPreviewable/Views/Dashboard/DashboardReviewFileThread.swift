import Foundation

/// One comment inside an inline review conversation. Carries everything the
/// inline thread card renders: author identity, body markdown, timestamp, and
/// the permalink back to GitHub.
struct DashboardReviewFileThreadComment: Equatable, Identifiable {
  let id: String
  let authorLogin: String?
  let authorAvatarURL: URL?
  let body: String
  let createdAt: String
  let url: String?
}

/// A review conversation anchored to a file line, carrying the full comment
/// list so the diff can render the thread inline (GitHub-style) rather than a
/// lossy badge. The lightweight ``DashboardReviewFileThreadAnchor`` used for
/// row matching and navigator badges is derived from this via ``anchor``.
struct DashboardReviewFileThread: Equatable, Identifiable {
  let id: String
  let path: String
  let side: DashboardReviewFileDiffSide?
  let line: Int?
  let diffPosition: Int?
  let isResolved: Bool
  let isCollapsed: Bool
  let authorLogin: String?
  let comments: [DashboardReviewFileThreadComment]

  var commentCount: Int { max(comments.count, 1) }
  var preview: String { comments.first?.body.anchorPreview ?? "" }
  var url: String? { comments.first?.url }

  var anchor: DashboardReviewFileThreadAnchor {
    DashboardReviewFileThreadAnchor(
      id: id,
      path: path,
      side: side,
      line: line,
      diffPosition: diffPosition,
      commentCount: commentCount,
      isResolved: isResolved,
      authorLogin: authorLogin,
      preview: preview,
      url: url
    )
  }
}
