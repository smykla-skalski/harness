import Foundation
import HarnessMonitorKit

private struct ReviewTimelineBaseNodeDescriptor {
  let identityID: String
  let timestamp: Date
  let rawTimestamp: String
  let sourceLabel: String
  let entryKind: String
  let title: String
  let detail: String?
  let tone: SessionTimelineTone
  let actorLogin: String?
  let actorAvatarURL: URL?
}

private struct ReviewInlineConversationSignature: Hashable {
  let path: String
  let anchorLine: Int32?
  let actorLogin: String?
  let createdAt: String
  let openingBody: String
}

/// Off-main builder that converts the daemon's PR timeline entries
/// into fully-baked `SessionTimelineNode` values for the shared
/// timeline renderer.
///
/// Every per-row string (`title`, `detail`, `voiceOverLabelOverride`,
/// `statusBadgeLabel`) is precomputed here so the SwiftUI view body
/// can stay POD-only — no JSON parsing or markdown work runs inside
/// `body` (see plan §4.3). Reviews activity inline conversations are
/// grouped here as dedicated thread cards so the renderer does not
/// need to reconstruct thread structure in `body`.
struct ReviewPullRequestTimelineNodeBuilder: Sendable {
  private static let heavyReviewThreadCommentThreshold = 6

  func buildNodes(
    for entries: [ReviewTimelineEntry],
    pullRequestID _: String,
    hiddenKinds: Set<ReviewTimelineKind> = [],
    autoCollapseHeavyReviewThreads: Bool = false,
    configuration _: HarnessMonitorDateTimeConfiguration
  ) -> [SessionTimelineNode] {
    let visibleReviewThreadSignatures =
      hiddenKinds.contains(.reviewThread)
      ? Set<ReviewInlineConversationSignature>()
      : Set(
        entries.compactMap { entry in
          guard case .reviewThread(let payload) = entry else { return nil }
          return Self.inlineConversationSignature(for: payload)
        }
      )
    var output: [SessionTimelineNode] = []
    output.reserveCapacity(entries.count)
    for entry in entries {
      guard !hiddenKinds.contains(entry.kind) else { continue }
      switch entry {
      case .issueComment(let payload):
        output.append(issueCommentNode(payload))
      case .review(let payload):
        output.append(
          contentsOf: reviewNodes(
            payload,
            visibleReviewThreadSignatures: visibleReviewThreadSignatures,
            autoCollapseHeavyReviewThreads: autoCollapseHeavyReviewThreads
          )
        )
      case .reviewThread(let payload):
        output.append(
          contentsOf: reviewThreadNodes(
            payload,
            autoCollapseHeavyReviewThreads: autoCollapseHeavyReviewThreads
          )
        )
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
      .init(
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
        actorLogin: payload.actor?.login,
        actorAvatarURL: payload.actor?.avatarURL
      )
    )
    node.canOpenFullContent = !payload.isMinimized && Self.hasRichContent(payload.body)
    node.statusBadgeLabel = payload.isMinimized ? "Hidden" : nil
    node.voiceOverLabelOverride =
      "\(payload.actor?.login ?? "Someone") commented at \(payload.createdAt)"
    return node
  }

  // MARK: - Review (parent + inline children)

  private func reviewNodes(
    _ payload: ReviewPayload,
    visibleReviewThreadSignatures: Set<ReviewInlineConversationSignature>,
    autoCollapseHeavyReviewThreads: Bool
  ) -> [SessionTimelineNode] {
    var nodes: [SessionTimelineNode] = []
    var parent = makeBaseNode(
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: Self.reviewSourceLabel(payload.state),
        entryKind: "pr.review.\(payload.state.rawValue)",
        title: Self.reviewTitle(actor: payload.actor, state: payload.state),
        detail: Self.compactBody(payload.body ?? ""),
        tone: Self.reviewTone(payload.state),
        actorLogin: payload.actor?.login,
        actorAvatarURL: payload.actor?.avatarURL
      )
    )
    parent.canOpenFullContent = Self.hasRichContent(payload.body)
    parent.statusBadgeLabel = payload.commentsTruncated ? "Truncated" : nil
    parent.voiceOverLabelOverride =
      "\(payload.actor?.login ?? "Someone") "
      + Self.reviewActionPhrase(payload.state)
      + " at \(payload.createdAt)"
    nodes.append(parent)
    for group in Self.inlineConversationGroups(payload.inlineComments) {
      if let signature = Self.inlineConversationSignature(for: group),
        visibleReviewThreadSignatures.contains(signature)
      {
        continue
      }
      let forceCollapsed =
        autoCollapseHeavyReviewThreads && group.count > Self.heavyReviewThreadCommentThreshold
      if let node = inlineConversationNode(
        group,
        parentReviewID: payload.id,
        forceCollapsed: forceCollapsed
      ) {
        nodes.append(node)
      }
    }
    return nodes
  }

  private func inlineConversationNode(
    _ payloads: [ReviewInlineCommentPayload],
    parentReviewID: String,
    forceCollapsed: Bool
  ) -> SessionTimelineNode? {
    guard
      let first = payloads.sorted(by: Self.inlineCommentSortPredicate).first,
      let conversation = DashboardReviewActivityInlineConversationBuilder.build(
        fromInlineCommentGroup: payloads,
        forceCollapsed: forceCollapsed
      )
    else {
      return nil
    }
    let identityID = "\(parentReviewID):\(first.id)"
    var node = makeBaseNode(
      .init(
        identityID: identityID,
        timestamp: Self.parse(first.createdAt),
        rawTimestamp: first.createdAt,
        sourceLabel: "Inline conversation",
        entryKind: "pr.review.inline_thread",
        title: Self.inlineConversationTitle(
          path: first.path,
          locationLabel: Self.locationLabel(for: first)
        ),
        detail: nil,
        tone: .info,
        actorLogin: nil,
        actorAvatarURL: nil
      )
    )
    node.reviewInlineConversation = conversation
    node.indentLevel = 1
    node.voiceOverLabelOverride =
      "Review conversation on \(first.path), \(Self.locationLabel(for: first)), \(conversation.thread.comments.count) comments"
    return node
  }

  // MARK: - Review thread conversation cards

  private func reviewThreadNodes(
    _ payload: ReviewThreadPayload,
    autoCollapseHeavyReviewThreads: Bool
  ) -> [SessionTimelineNode] {
    let forceCollapsed =
      autoCollapseHeavyReviewThreads
      && payload.comments.count > Self.heavyReviewThreadCommentThreshold
    guard
      let conversation = DashboardReviewActivityInlineConversationBuilder.build(
        from: payload,
        forceCollapsed: forceCollapsed
      )
    else {
      return []
    }
    var node = makeBaseNode(
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: "Review conversation",
        entryKind: "pr.review_thread.conversation",
        title: Self.inlineConversationTitle(
          path: payload.path,
          locationLabel: Self.locationLabel(for: payload)
        ),
        detail: nil,
        tone: .info,
        actorLogin: nil,
        actorAvatarURL: nil
      )
    )
    node.reviewInlineConversation = conversation
    node.voiceOverLabelOverride =
      "Review conversation on \(payload.path), \(Self.locationLabel(for: payload)), \(conversation.thread.comments.count) comments"
    return [node]
  }

  // MARK: - Commit + head-ref force-push

  private func commitNode(_ payload: CommitPayload) -> SessionTimelineNode {
    let who = payload.authorLogin ?? payload.authorName ?? "Someone"
    var node = makeBaseNode(
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: "Commit",
        entryKind: "pr.commit",
        title: "\(who) pushed \(payload.abbreviatedOid)",
        detail: Self.compactBody(payload.messageHeadline),
        tone: .info,
        actorLogin: payload.authorLogin,
        actorAvatarURL: payload.actor?.avatarURL
      )
    )
    node.canOpenFullContent = Self.hasRichContent(payload.messageHeadline)
    node.statusBadgeLabel = payload.abbreviatedOid
    return node
  }

  private func headRefForcePushedNode(
    _ payload: HeadRefForcePushedPayload
  ) -> SessionTimelineNode {
    let branch = payload.refName ?? "branch"
    var node = makeBaseNode(
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: "Force push",
        entryKind: "pr.head_ref_force_pushed",
        title: "\(Self.actorTitle(payload.actor, fallback: "Someone")) force-pushed \(branch)",
        detail: "\(payload.beforeAbbreviatedOid) → \(payload.afterAbbreviatedOid)",
        tone: .warning,
        actorLogin: payload.actor?.login,
        actorAvatarURL: payload.actor?.avatarURL
      )
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
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: descriptor.sourceLabel,
        entryKind: "pr.\(payload.eventKind.rawValue)",
        title: descriptor.title(actor: payload.actor),
        detail: descriptor.detail,
        tone: descriptor.tone,
        actorLogin: payload.actor?.login,
        actorAvatarURL: payload.actor?.avatarURL
      )
    )
    if let badge = descriptor.statusBadge {
      node.statusBadgeLabel = badge
    }
    return node
  }

  private func unknownNode(_ payload: UnknownTimelinePayload) -> SessionTimelineNode {
    var node = makeBaseNode(
      .init(
        identityID: payload.id,
        timestamp: Self.parse(payload.createdAt),
        rawTimestamp: payload.createdAt,
        sourceLabel: "GitHub event",
        entryKind: "pr.unknown",
        title: payload.typename,
        detail: payload.actor?.login,
        tone: .info,
        actorLogin: payload.actor?.login,
        actorAvatarURL: payload.actor?.avatarURL
      )
    )
    node.statusBadgeLabel = "New event type"
    return node
  }

  // MARK: - Helpers

  private func makeBaseNode(
    _ descriptor: ReviewTimelineBaseNodeDescriptor
  ) -> SessionTimelineNode {
    var node = SessionTimelineNode(
      identity: .entry(descriptor.identityID),
      kind: .event,
      timestamp: descriptor.timestamp,
      rawTimestamp: descriptor.rawTimestamp,
      sourceLabel: descriptor.sourceLabel,
      entryKind: descriptor.entryKind,
      title: descriptor.title,
      detail: descriptor.detail,
      eventTone: descriptor.tone,
      decision: nil
    )
    node.actorLogin = descriptor.actorLogin
    node.actorAvatarURL = descriptor.actorAvatarURL
    return node
  }

  private static func parse(_ raw: String) -> Date {
    SessionTimelineTimestampParser.parse(raw) ?? .distantPast
  }

  private static func actorTitle(
    _ actor: ReviewTimelineActor?,
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

  private static func hasRichContent(_ body: String?) -> Bool {
    compactBody(body ?? "") != nil
  }

  private static func inlineConversationGroups(
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

  private static func inlineConversationRootID(
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

  private static func inlineCommentSortPredicate(
    lhs: ReviewInlineCommentPayload,
    rhs: ReviewInlineCommentPayload
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.id < rhs.id
  }

  private static func inlineConversationSignature(
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

  private static func inlineConversationSignature(
    for payloads: [ReviewInlineCommentPayload]
  ) -> ReviewInlineConversationSignature? {
    guard
      let first = payloads.sorted(by: inlineCommentSortPredicate).first,
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

  private static func normalizedConversationBody(_ body: String) -> String {
    body.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func inlineConversationTitle(path: String, locationLabel: String) -> String {
    "\(path) · \(locationLabel)"
  }

  private static func locationLabel(for payload: ReviewThreadPayload) -> String {
    if payload.outdated {
      return "Outdated"
    }
    if let line = payload.anchorLine(side: DashboardReviewFileDiffSide(wireValue: payload.diffSide))
    {
      return "Line \(line)"
    }
    return "Comment context"
  }

  private static func locationLabel(for payload: ReviewInlineCommentPayload) -> String {
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

  private static func reviewSourceLabel(_ state: ReviewReviewState) -> String {
    switch state {
    case .pending: return "Pending review"
    case .commented: return "Review comment"
    case .approved: return "Approval"
    case .changesRequested: return "Changes requested"
    case .dismissed: return "Dismissed review"
    }
  }

  private static func reviewTone(_ state: ReviewReviewState) -> SessionTimelineTone {
    switch state {
    case .approved: return .success
    case .changesRequested: return .warning
    case .pending, .commented, .dismissed: return .info
    }
  }

  private static func reviewTitle(
    actor: ReviewTimelineActor?,
    state: ReviewReviewState
  ) -> String {
    let who = actor?.login ?? "Someone"
    return "\(who) \(reviewActionPhrase(state))"
  }

  private static func reviewActionPhrase(_ state: ReviewReviewState) -> String {
    switch state {
    case .pending: return "started a review"
    case .commented: return "left review comments"
    case .approved: return "approved"
    case .changesRequested: return "requested changes"
    case .dismissed: return "dismissed a review"
    }
  }

}
