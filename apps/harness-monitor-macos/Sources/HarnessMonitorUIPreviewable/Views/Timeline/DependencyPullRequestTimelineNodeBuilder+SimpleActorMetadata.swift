import HarnessMonitorKit

extension DependencyPullRequestTimelineNodeBuilder {
  static func metadataDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .renamedTitle:
      let from = payload.oldTitle ?? ""
      let to = payload.newTitle ?? ""
      return .init(
        sourceLabel: "Renamed",
        actionPhrase: "renamed the title",
        detail: "\(from) → \(to)",
        tone: .info,
        statusBadge: nil
      )
    case .pinned:
      return .init(
        sourceLabel: "Pinned",
        actionPhrase: "pinned this PR",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .unpinned:
      return .init(
        sourceLabel: "Unpinned",
        actionPhrase: "unpinned this PR",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .milestoned:
      return .init(
        sourceLabel: "Milestone",
        actionPhrase: "added to milestone",
        detail: payload.milestoneTitle,
        tone: .info,
        statusBadge: nil
      )
    case .demilestoned:
      return .init(
        sourceLabel: "Milestone",
        actionPhrase: "removed from milestone",
        detail: payload.milestoneTitle,
        tone: .info,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  static func referenceLinkDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .referenced:
      return .init(
        sourceLabel: "Referenced",
        actionPhrase: "referenced this PR",
        detail: payload.sourceTitle,
        tone: .info,
        statusBadge: nil
      )
    case .crossReferenced:
      let repo = payload.sourceRepository ?? ""
      return .init(
        sourceLabel: "Cross-referenced",
        actionPhrase: "cross-referenced from \(repo)",
        detail: payload.sourceTitle,
        tone: .info,
        statusBadge: nil
      )
    case .connected:
      return .init(
        sourceLabel: "Linked",
        actionPhrase: "linked this PR to an issue",
        detail: payload.sourceTitle,
        tone: .info,
        statusBadge: nil
      )
    case .disconnected:
      return .init(
        sourceLabel: "Linked",
        actionPhrase: "unlinked an issue",
        detail: payload.sourceTitle,
        tone: .info,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  static func notificationDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .mentioned:
      return .init(
        sourceLabel: "Mention",
        actionPhrase: "was mentioned",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .subscribed:
      return .init(
        sourceLabel: "Subscription",
        actionPhrase: "subscribed",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .unsubscribed:
      return .init(
        sourceLabel: "Subscription",
        actionPhrase: "unsubscribed",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .markedAsDuplicate:
      return .init(
        sourceLabel: "Duplicate",
        actionPhrase: "marked this PR as duplicate",
        detail: nil,
        tone: .warning,
        statusBadge: "Duplicate"
      )
    case .unmarkedAsDuplicate:
      return .init(
        sourceLabel: "Duplicate",
        actionPhrase: "unmarked the duplicate flag",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .transferred:
      let destination = payload.destinationRepository ?? "another repo"
      return .init(
        sourceLabel: "Transferred",
        actionPhrase: "transferred this PR to \(destination)",
        detail: nil,
        tone: .warning,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  static func requestedReviewerName(_ payload: SimpleActorEventPayload) -> String {
    payload.requestedReviewerLogin
      ?? payload.requestedReviewerTeamSlug.map { "@\($0)" }
      ?? "someone"
  }
}
