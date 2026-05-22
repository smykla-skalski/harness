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
      default:
        // Remaining variants land in subsequent C.7 / C.8 / C.9
        // commits via family-grouped companion files.
        continue
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
