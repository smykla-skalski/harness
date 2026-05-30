import Foundation
import HarnessMonitorKit

extension ReviewPullRequestTimelineNodeBuilder {
  static func parse(_ raw: String) -> Date {
    SessionTimelineTimestampParser.parse(raw) ?? .distantPast
  }

  static func actorTitle(
    _ actor: ReviewTimelineActor?,
    fallback: String
  ) -> String {
    actor?.login ?? fallback
  }

  static func compactBody(_ body: String) -> String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= 280 { return trimmed }
    let prefix = trimmed.prefix(279)
    return prefix + "…"
  }

  static func hasRichContent(_ body: String?) -> Bool {
    compactBody(body ?? "") != nil
  }

  static func inlineConversationGroups(
    _ comments: [ReviewInlineCommentPayload]
  ) -> [[ReviewInlineCommentPayload]] {
    let commentsByID = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0) })
    var grouped: [String: [ReviewInlineCommentPayload]] = [:]
    var orderedKeys: [String] = []
    for comment in comments {
      let key = inlineConversationRootID(for: comment, commentsByID: commentsByID)
      if grouped[key] == nil {
        orderedKeys.append(key)
      }
      grouped[key, default: []].append(comment)
    }
    return orderedKeys.compactMap { key in
      grouped[key]?.sorted(by: inlineCommentSortPredicate)
    }
  }

  static func inlineConversationRootID(
    for comment: ReviewInlineCommentPayload,
    commentsByID: [String: ReviewInlineCommentPayload]
  ) -> String {
    var current = comment
    var visited = Set([comment.id])
    while let replyToID = current.replyToId,
      let parent = commentsByID[replyToID],
      !visited.contains(parent.id)
    {
      current = parent
      visited.insert(parent.id)
    }
    return current.id
  }

  static func inlineCommentSortPredicate(
    lhs: ReviewInlineCommentPayload,
    rhs: ReviewInlineCommentPayload
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id < rhs.id
  }

  static func inlineConversationSignature(
    for payload: ReviewThreadPayload
  ) -> ReviewInlineConversationSignature? {
    guard let firstComment = payload.comments.first, !payload.path.isEmpty else { return nil }
    return ReviewInlineConversationSignature(
      path: payload.path,
      anchorLine: payload.anchorLine(
        side: DashboardReviewFileDiffSide(wireValue: payload.diffSide)),
      actorLogin: firstComment.actor?.login ?? payload.actor?.login,
      createdAt: firstComment.createdAt,
      openingBody: normalizedConversationBody(firstComment.body)
    )
  }

  static func inlineConversationSignature(
    for payloads: [ReviewInlineCommentPayload]
  ) -> ReviewInlineConversationSignature? {
    guard
      let first = payloads.min(by: inlineCommentSortPredicate),
      !first.path.isEmpty
    else {
      return nil
    }
    return ReviewInlineConversationSignature(
      path: first.path,
      anchorLine: first.anchorLine(),
      actorLogin: first.actor?.login,
      createdAt: first.createdAt,
      openingBody: normalizedConversationBody(first.body)
    )
  }

  static func normalizedConversationBody(_ body: String) -> String {
    body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func inlineConversationTitle(path: String, locationLabel: String) -> String {
    "\(path) · \(locationLabel)"
  }

  static func locationLabel(for payload: ReviewThreadPayload) -> String {
    if payload.outdated {
      return "Outdated"
    }
    if let line = payload.anchorLine(side: DashboardReviewFileDiffSide(wireValue: payload.diffSide))
    {
      return "Line \(line)"
    }
    return "Comment context"
  }

  static func locationLabel(for payload: ReviewInlineCommentPayload) -> String {
    if payload.outdated {
      return "Outdated"
    }
    if let line = payload.anchorLine() {
      return "Line \(line)"
    }
    if let position = payload.position {
      return "Position \(position)"
    }
    return "Comment context"
  }

  static func reviewSourceLabel(_ state: ReviewReviewState) -> String {
    switch state {
    case .pending: return "Pending review"
    case .commented: return "Review comment"
    case .approved: return "Approval"
    case .changesRequested: return "Changes requested"
    case .dismissed: return "Dismissed review"
    }
  }

  static func reviewTone(_ state: ReviewReviewState) -> SessionTimelineTone {
    switch state {
    case .approved: return .success
    case .changesRequested: return .warning
    case .pending, .commented, .dismissed: return .info
    }
  }

  static func reviewTitle(
    actor: ReviewTimelineActor?,
    state: ReviewReviewState
  ) -> String {
    let who = actor?.login ?? "Someone"
    return "\(who) \(reviewActionPhrase(state))"
  }

  static func reviewActionPhrase(_ state: ReviewReviewState) -> String {
    switch state {
    case .pending: return "started a review"
    case .commented: return "left review comments"
    case .approved: return "approved"
    case .changesRequested: return "requested changes"
    case .dismissed: return "dismissed a review"
    }
  }
}
