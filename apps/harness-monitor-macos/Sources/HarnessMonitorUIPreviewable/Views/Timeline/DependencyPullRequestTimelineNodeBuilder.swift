import Foundation
import HarnessMonitorKit

/// Off-main builder that converts the daemon's PR timeline entries
/// into fully-baked `SessionTimelineNode` values for the shared
/// timeline renderer.
///
/// Every per-row string (`title`, `detail`, `voiceOverLabelOverride`,
/// `statusBadgeLabel`) is precomputed here so the SwiftUI view body
/// can stay POD-only — no JSON parsing or markdown work runs inside
/// `body` (see plan §4.3). Inline review comments are emitted as
/// indented sibling rows beneath their parent review card; the
/// renderer applies `indentLevel * 16pt` leading padding.
struct DependencyPullRequestTimelineNodeBuilder: Sendable {
  init() {}

  func buildNodes(
    for entries: [DependencyUpdateTimelineEntry],
    pullRequestID _: String,
    hiddenKinds: Set<DependencyUpdateTimelineKind> = [],
    configuration _: HarnessMonitorDateTimeConfiguration
  ) -> [SessionTimelineNode] {
    var output: [SessionTimelineNode] = []
    output.reserveCapacity(entries.count)
    for entry in entries {
      guard !hiddenKinds.contains(entry.kind) else { continue }
      switch entry {
      case .issueComment(let payload):
        output.append(issueCommentNode(payload))
      case .review(let payload):
        output.append(contentsOf: reviewNodes(payload))
      case .reviewThread(let payload):
        output.append(contentsOf: reviewThreadNodes(payload))
      case .commit(let payload):
        output.append(commitNode(payload))
      case .headRefForcePushed(let payload):
        output.append(headRefForcePushedNode(payload))
      case .simpleActorEvent(let payload):
        output.append(simpleActorEventNode(payload))
      case .unknown(let payload):
        output.append(unknownNode(payload))
      }
    }
    return output
  }

  // MARK: - Issue comment

  private func issueCommentNode(_ payload: IssueCommentPayload) -> SessionTimelineNode {
    var node = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: "Comment",
      entryKind: "pr.issue_comment",
      title: Self.actorTitle(payload.actor, fallback: "Someone")
        + (payload.viewerDidAuthor ? " (you)" : "")
        + " commented",
      detail: Self.compactBody(payload.body),
      tone: .info,
      actorLogin: payload.actor?.login
    )
    node.statusBadgeLabel = payload.isMinimized ? "Hidden" : nil
    node.voiceOverLabelOverride =
      "\(payload.actor?.login ?? "Someone") commented at \(payload.createdAt)"
    return node
  }

  // MARK: - Review (parent + inline children)

  private func reviewNodes(_ payload: ReviewPayload) -> [SessionTimelineNode] {
    var nodes: [SessionTimelineNode] = []
    var parent = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: Self.reviewSourceLabel(payload.state),
      entryKind: "pr.review.\(payload.state.rawValue)",
      title: Self.reviewTitle(actor: payload.actor, state: payload.state),
      detail: Self.compactBody(payload.body ?? ""),
      tone: Self.reviewTone(payload.state),
      actorLogin: payload.actor?.login
    )
    parent.statusBadgeLabel = payload.commentsTruncated ? "Truncated" : nil
    parent.voiceOverLabelOverride =
      "\(payload.actor?.login ?? "Someone") "
      + Self.reviewActionPhrase(payload.state)
      + " at \(payload.createdAt)"
    nodes.append(parent)

    for inline in payload.inlineComments {
      nodes.append(inlineCommentNode(inline, parentReviewID: payload.id))
    }
    return nodes
  }

  private func inlineCommentNode(
    _ payload: ReviewInlineCommentPayload,
    parentReviewID: String
  ) -> SessionTimelineNode {
    var node = makeBaseNode(
      identityID: "\(parentReviewID):\(payload.id)",
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: "Inline comment",
      entryKind: "pr.review.inline_comment",
      title: Self.actorTitle(payload.actor, fallback: "Reviewer") + " on \(payload.path)",
      detail: Self.compactBody(payload.body),
      tone: .info,
      actorLogin: payload.actor?.login
    )
    node.indentLevel = 1
    node.prefersCompactLayout = true
    if let position = payload.position {
      node.statusBadgeLabel = "Line \(position)"
    }
    return node
  }

  // MARK: - Review thread (parent + comment children)

  private func reviewThreadNodes(_ payload: ReviewThreadPayload) -> [SessionTimelineNode] {
    var nodes: [SessionTimelineNode] = []
    let lineLabel = payload.line.map { "line \($0)" } ?? "(line unknown)"
    var parent = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: payload.isResolved ? "Review thread (resolved)" : "Review thread",
      entryKind: "pr.review_thread",
      title: "\(payload.path) · \(lineLabel)",
      detail: nil,
      tone: payload.isResolved ? .info : .info,
      actorLogin: payload.actor?.login
    )
    parent.statusBadgeLabel = payload.isResolved ? "Resolved" : nil
    if payload.commentsTruncated {
      parent.statusBadgeLabel = "Truncated"
    }
    nodes.append(parent)
    for comment in payload.comments {
      var child = makeBaseNode(
        identityID: "\(payload.id):\(comment.id)",
        timestamp: Self.parse(comment.createdAt),
        rawTimestamp: comment.createdAt,
        sourceLabel: "Thread comment",
        entryKind: "pr.review_thread.comment",
        title: Self.actorTitle(comment.actor, fallback: "Reviewer"),
        detail: Self.compactBody(comment.body),
        tone: .info,
        actorLogin: comment.actor?.login
      )
      child.indentLevel = 1
      child.prefersCompactLayout = true
      nodes.append(child)
    }
    return nodes
  }

  // MARK: - Commit + head-ref force-push

  private func commitNode(_ payload: CommitPayload) -> SessionTimelineNode {
    let who = payload.authorLogin ?? payload.authorName ?? "Someone"
    var node = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: "Commit",
      entryKind: "pr.commit",
      title: "\(who) pushed \(payload.abbreviatedOid)",
      detail: Self.compactBody(payload.messageHeadline),
      tone: .info,
      actorLogin: payload.authorLogin
    )
    node.statusBadgeLabel = payload.abbreviatedOid
    return node
  }

  private func headRefForcePushedNode(
    _ payload: HeadRefForcePushedPayload
  ) -> SessionTimelineNode {
    let branch = payload.refName ?? "branch"
    var node = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: "Force push",
      entryKind: "pr.head_ref_force_pushed",
      title: "\(Self.actorTitle(payload.actor, fallback: "Someone")) force-pushed \(branch)",
      detail: "\(payload.beforeAbbreviatedOid) → \(payload.afterAbbreviatedOid)",
      tone: .warning,
      actorLogin: payload.actor?.login
    )
    node.statusBadgeLabel = "Force push"
    return node
  }

  // MARK: - Simple actor events (39 lightweight kinds)

  private func simpleActorEventNode(
    _ payload: SimpleActorEventPayload
  ) -> SessionTimelineNode {
    let descriptor = Self.simpleActorDescriptor(payload)
    var node = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: descriptor.sourceLabel,
      entryKind: "pr.\(payload.eventKind.rawValue)",
      title: descriptor.title(actor: payload.actor),
      detail: descriptor.detail,
      tone: descriptor.tone,
      actorLogin: payload.actor?.login
    )
    if let badge = descriptor.statusBadge {
      node.statusBadgeLabel = badge
    }
    return node
  }

  private func unknownNode(_ payload: UnknownTimelinePayload) -> SessionTimelineNode {
    var node = makeBaseNode(
      identityID: payload.id,
      timestamp: Self.parse(payload.createdAt),
      rawTimestamp: payload.createdAt,
      sourceLabel: "GitHub event",
      entryKind: "pr.unknown",
      title: payload.typename,
      detail: payload.actor?.login,
      tone: .info,
      actorLogin: payload.actor?.login
    )
    node.statusBadgeLabel = "New event type"
    return node
  }

  // MARK: - Helpers

  private func makeBaseNode(
    identityID: String,
    timestamp: Date,
    rawTimestamp: String,
    sourceLabel: String,
    entryKind: String,
    title: String,
    detail: String?,
    tone: SessionTimelineTone,
    actorLogin: String?
  ) -> SessionTimelineNode {
    var node = SessionTimelineNode(
      identity: .entry(identityID),
      kind: .event,
      timestamp: timestamp,
      rawTimestamp: rawTimestamp,
      sourceLabel: sourceLabel,
      entryKind: entryKind,
      title: title,
      detail: detail,
      eventTone: tone,
      decision: nil
    )
    node.actorLogin = actorLogin
    return node
  }

  private static func parse(_ raw: String) -> Date {
    SessionTimelineTimestampParser.parse(raw) ?? .distantPast
  }

  private static func actorTitle(
    _ actor: DependencyUpdateTimelineActor?,
    fallback: String
  ) -> String {
    actor?.login ?? fallback
  }

  private static func compactBody(_ body: String) -> String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= 280 { return trimmed }
    let prefix = trimmed.prefix(279)
    return prefix + "…"
  }

  private static func reviewSourceLabel(_ state: DependencyUpdateReviewState) -> String {
    switch state {
    case .pending: return "Pending review"
    case .commented: return "Review comment"
    case .approved: return "Approval"
    case .changesRequested: return "Changes requested"
    case .dismissed: return "Dismissed review"
    }
  }

  private static func reviewTone(_ state: DependencyUpdateReviewState) -> SessionTimelineTone {
    switch state {
    case .approved: return .success
    case .changesRequested: return .warning
    case .pending, .commented, .dismissed: return .info
    }
  }

  private static func reviewTitle(
    actor: DependencyUpdateTimelineActor?,
    state: DependencyUpdateReviewState
  ) -> String {
    let who = actor?.login ?? "Someone"
    return "\(who) \(reviewActionPhrase(state))"
  }

  private static func reviewActionPhrase(_ state: DependencyUpdateReviewState) -> String {
    switch state {
    case .pending: return "started a review"
    case .commented: return "left review comments"
    case .approved: return "approved"
    case .changesRequested: return "requested changes"
    case .dismissed: return "dismissed a review"
    }
  }

}
