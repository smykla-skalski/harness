import Foundation
import HarnessMonitorKit

/// Descriptor produced from a `SimpleActorEventPayload` by the
/// node-builder's lookup table. Carries the strings/tone/badge the
/// renderer needs without re-inspecting the payload at view time.
struct SimpleActorDescriptor {
  let sourceLabel: String
  let actionPhrase: String
  let detail: String?
  let tone: SessionTimelineTone
  let statusBadge: String?

  func title(actor: ReviewTimelineActor?) -> String {
    let who = actor?.login ?? "Someone"
    return "\(who) \(actionPhrase)"
  }
}

extension ReviewPullRequestTimelineNodeBuilder {
  static func simpleActorDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor {
    if let descriptor = branchDescriptor(payload) { return descriptor }
    if let descriptor = labelAssignmentReviewDescriptor(payload) { return descriptor }
    if let descriptor = lifecycleDescriptor(payload) { return descriptor }
    if let descriptor = automationAndLockDescriptor(payload) { return descriptor }
    if let descriptor = metadataDescriptor(payload) { return descriptor }
    if let descriptor = referenceLinkDescriptor(payload) { return descriptor }
    if let descriptor = notificationDescriptor(payload) { return descriptor }
    return .init(
      sourceLabel: "GitHub event",
      actionPhrase: "updated this PR",
      detail: nil,
      tone: .info,
      statusBadge: nil
    )
  }

  private static func branchDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .baseRefChanged:
      let from = payload.oldTitle ?? "?"
      let to = payload.newTitle ?? "?"
      return .init(
        sourceLabel: "Base branch",
        actionPhrase: "changed the base branch",
        detail: "\(from) → \(to)",
        tone: .warning,
        statusBadge: nil
      )
    case .baseRefForcePushed:
      let branch = payload.branchName ?? "base"
      let before = payload.beforeOid.map { String($0.prefix(7)) } ?? "?"
      let after = payload.afterOid.map { String($0.prefix(7)) } ?? "?"
      return .init(
        sourceLabel: "Base force push",
        actionPhrase: "force-pushed base branch \(branch)",
        detail: "\(before) → \(after)",
        tone: .warning,
        statusBadge: "Force push"
      )
    case .baseRefDeleted:
      return .init(
        sourceLabel: "Base branch",
        actionPhrase: "deleted the base branch",
        detail: payload.branchName,
        tone: .critical,
        statusBadge: nil
      )
    case .headRefDeleted:
      return .init(
        sourceLabel: "Head branch",
        actionPhrase: "deleted the head branch",
        detail: payload.branchName,
        tone: .info,
        statusBadge: nil
      )
    case .headRefRestored:
      return .init(
        sourceLabel: "Head branch",
        actionPhrase: "restored the head branch",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .revisionMarker:
      let oid = payload.afterOid.map { String($0.prefix(7)) } ?? "?"
      return .init(
        sourceLabel: "Revision",
        actionPhrase: "reviewed since commit \(oid)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  private static func labelAssignmentReviewDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .labeled:
      let label = payload.label ?? "a label"
      return .init(
        sourceLabel: "Label",
        actionPhrase: "added \(label)",
        detail: nil,
        tone: .info,
        statusBadge: payload.labelColor.map { "#\($0)" }
      )
    case .unlabeled:
      let label = payload.label ?? "a label"
      return .init(
        sourceLabel: "Label",
        actionPhrase: "removed \(label)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .assigned:
      let who = payload.assigneeLogin ?? "someone"
      return .init(
        sourceLabel: "Assignment",
        actionPhrase: "assigned \(who)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .unassigned:
      let who = payload.assigneeLogin ?? "someone"
      return .init(
        sourceLabel: "Assignment",
        actionPhrase: "unassigned \(who)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .reviewRequested:
      let who = requestedReviewerName(payload)
      return .init(
        sourceLabel: "Review requested",
        actionPhrase: "requested a review from \(who)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .reviewRequestRemoved:
      let who = requestedReviewerName(payload)
      return .init(
        sourceLabel: "Review request removed",
        actionPhrase: "removed review request from \(who)",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .reviewDismissed:
      return .init(
        sourceLabel: "Review dismissed",
        actionPhrase: "dismissed a review",
        detail: payload.dismissalMessage,
        tone: .warning,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  private static func lifecycleDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .merged:
      let oid = payload.afterOid.map { String($0.prefix(7)) } ?? "?"
      let branch = payload.branchName ?? "base"
      return .init(
        sourceLabel: "Merged",
        actionPhrase: "merged \(oid) into \(branch)",
        detail: nil,
        tone: .success,
        statusBadge: "Merged"
      )
    case .closed:
      return .init(
        sourceLabel: "Closed",
        actionPhrase: "closed this PR",
        detail: nil,
        tone: .warning,
        statusBadge: nil
      )
    case .reopened:
      return .init(
        sourceLabel: "Reopened",
        actionPhrase: "reopened this PR",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .readyForReview:
      return .init(
        sourceLabel: "Ready for review",
        actionPhrase: "marked this ready for review",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .convertToDraft:
      return .init(
        sourceLabel: "Draft",
        actionPhrase: "converted this back to a draft",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

  private static func automationAndLockDescriptor(
    _ payload: SimpleActorEventPayload
  ) -> SimpleActorDescriptor? {
    switch payload.eventKind {
    case .autoMergeEnabled:
      return .init(
        sourceLabel: "Auto-merge",
        actionPhrase: "enabled auto-merge",
        detail: nil,
        tone: .info,
        statusBadge: "Auto-merge"
      )
    case .autoMergeDisabled:
      return .init(
        sourceLabel: "Auto-merge",
        actionPhrase: "disabled auto-merge",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    case .autoRebaseEnabled:
      return .init(
        sourceLabel: "Auto-rebase",
        actionPhrase: "enabled auto-rebase",
        detail: nil,
        tone: .info,
        statusBadge: "Auto-rebase"
      )
    case .autoSquashEnabled:
      return .init(
        sourceLabel: "Auto-squash",
        actionPhrase: "enabled auto-squash",
        detail: nil,
        tone: .info,
        statusBadge: "Auto-squash"
      )
    case .locked:
      return .init(
        sourceLabel: "Locked",
        actionPhrase: "locked this conversation",
        detail: payload.lockReason,
        tone: .warning,
        statusBadge: nil
      )
    case .unlocked:
      return .init(
        sourceLabel: "Unlocked",
        actionPhrase: "unlocked this conversation",
        detail: nil,
        tone: .info,
        statusBadge: nil
      )
    default:
      return nil
    }
  }

}
