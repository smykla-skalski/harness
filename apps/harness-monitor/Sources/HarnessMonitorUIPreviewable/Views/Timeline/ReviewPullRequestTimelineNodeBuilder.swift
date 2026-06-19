import Foundation
import HarnessMonitorKit

struct ReviewTimelineBaseNodeDescriptor {
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

struct ReviewInlineConversationSignature: Hashable {
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
    showInlineComments: Bool = true,
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
      appendNodes(
        for: entry,
        into: &output,
        showInlineComments: showInlineComments,
        autoCollapseHeavyReviewThreads: autoCollapseHeavyReviewThreads,
        visibleReviewThreadSignatures: visibleReviewThreadSignatures
      )
    }
    return output
  }

  private func appendNodes(
    for entry: ReviewTimelineEntry,
    into output: inout [SessionTimelineNode],
    showInlineComments: Bool,
    autoCollapseHeavyReviewThreads: Bool,
    visibleReviewThreadSignatures: Set<ReviewInlineConversationSignature>
  ) {
    switch entry {
    case .issueComment(let payload):
      output.append(issueCommentNode(payload))
    case .review(let payload):
      output.append(
        contentsOf: reviewNodes(
          payload,
          visibleReviewThreadSignatures: visibleReviewThreadSignatures,
          showInlineComments: showInlineComments,
          autoCollapseHeavyReviewThreads: autoCollapseHeavyReviewThreads
        )
      )
    case .reviewThread(let payload):
      guard showInlineComments else { return }
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
    showInlineComments: Bool,
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
    guard showInlineComments else { return nodes }
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
      let first = payloads.min(by: Self.inlineCommentSortPredicate),
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
    let commentCount = conversation.thread.comments.count
    node.voiceOverLabelOverride =
      "Review conversation on \(first.path), "
      + "\(Self.locationLabel(for: first)), \(commentCount) comments"
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
    let commentCount = conversation.thread.comments.count
    node.voiceOverLabelOverride =
      "Review conversation on \(payload.path), "
      + "\(Self.locationLabel(for: payload)), \(commentCount) comments"
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
}
