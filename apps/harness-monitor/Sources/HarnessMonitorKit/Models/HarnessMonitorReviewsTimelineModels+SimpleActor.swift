import Foundation

public enum SimpleActorEventKind: String, Codable, Equatable, Sendable {
  case headRefDeleted = "head_ref_deleted"
  case headRefRestored = "head_ref_restored"
  case baseRefChanged = "base_ref_changed"
  case baseRefForcePushed = "base_ref_force_pushed"
  case baseRefDeleted = "base_ref_deleted"
  case labeled
  case unlabeled
  case assigned
  case unassigned
  case merged
  case closed
  case reopened
  case renamedTitle = "renamed_title"
  case reviewRequested = "review_requested"
  case reviewRequestRemoved = "review_request_removed"
  case reviewDismissed = "review_dismissed"
  case readyForReview = "ready_for_review"
  case convertToDraft = "convert_to_draft"
  case autoMergeEnabled = "auto_merge_enabled"
  case autoMergeDisabled = "auto_merge_disabled"
  case autoRebaseEnabled = "auto_rebase_enabled"
  case autoSquashEnabled = "auto_squash_enabled"
  case locked
  case unlocked
  case pinned
  case unpinned
  case milestoned
  case demilestoned
  case referenced
  case crossReferenced = "cross_referenced"
  case mentioned
  case subscribed
  case unsubscribed
  case markedAsDuplicate = "marked_as_duplicate"
  case unmarkedAsDuplicate = "unmarked_as_duplicate"
  case transferred
  case connected
  case disconnected
  case revisionMarker = "revision_marker"

  public var timelineKind: ReviewTimelineKind {
    switch self {
    case .headRefDeleted: return .headRefDeleted
    case .headRefRestored: return .headRefRestored
    case .baseRefChanged: return .baseRefChanged
    case .baseRefForcePushed: return .baseRefForcePushed
    case .baseRefDeleted: return .baseRefDeleted
    case .labeled: return .labeled
    case .unlabeled: return .unlabeled
    case .assigned: return .assigned
    case .unassigned: return .unassigned
    case .merged: return .merged
    case .closed: return .closed
    case .reopened: return .reopened
    case .renamedTitle: return .renamedTitle
    case .reviewRequested: return .reviewRequested
    case .reviewRequestRemoved: return .reviewRequestRemoved
    case .reviewDismissed: return .reviewDismissed
    case .readyForReview: return .readyForReview
    case .convertToDraft: return .convertToDraft
    case .autoMergeEnabled: return .autoMergeEnabled
    case .autoMergeDisabled: return .autoMergeDisabled
    case .autoRebaseEnabled: return .autoRebaseEnabled
    case .autoSquashEnabled: return .autoSquashEnabled
    case .locked: return .locked
    case .unlocked: return .unlocked
    case .pinned: return .pinned
    case .unpinned: return .unpinned
    case .milestoned: return .milestoned
    case .demilestoned: return .demilestoned
    case .referenced: return .referenced
    case .crossReferenced: return .crossReferenced
    case .mentioned: return .mentioned
    case .subscribed: return .subscribed
    case .unsubscribed: return .unsubscribed
    case .markedAsDuplicate: return .markedAsDuplicate
    case .unmarkedAsDuplicate: return .unmarkedAsDuplicate
    case .transferred: return .transferred
    case .connected: return .connected
    case .disconnected: return .disconnected
    case .revisionMarker: return .revisionMarker
    }
  }
}

public struct SimpleActorEventPayload: Codable, Equatable, Sendable {
  public let id: String
  public let createdAt: String
  public let actor: ReviewTimelineActor?
  public let eventKind: SimpleActorEventKind
  public let label: String?
  public let labelColor: String?
  public let milestoneTitle: String?
  public let oldTitle: String?
  public let newTitle: String?
  public let sourceURL: String?
  public let sourceTitle: String?
  public let sourceNumber: Int64?
  public let branchName: String?
  public let beforeOid: String?
  public let afterOid: String?
  public let lockReason: String?
  public let dismissalMessage: String?
  public let requestedReviewerLogin: String?
  public let requestedReviewerTeamSlug: String?
  public let assigneeLogin: String?
  public let sourceRepository: String?
  public let destinationRepository: String?

  public init(
    id: String,
    createdAt: String,
    actor: ReviewTimelineActor? = nil,
    eventKind: SimpleActorEventKind,
    label: String? = nil,
    labelColor: String? = nil,
    milestoneTitle: String? = nil,
    oldTitle: String? = nil,
    newTitle: String? = nil,
    sourceURL: String? = nil,
    sourceTitle: String? = nil,
    sourceNumber: Int64? = nil,
    branchName: String? = nil,
    beforeOid: String? = nil,
    afterOid: String? = nil,
    lockReason: String? = nil,
    dismissalMessage: String? = nil,
    requestedReviewerLogin: String? = nil,
    requestedReviewerTeamSlug: String? = nil,
    assigneeLogin: String? = nil,
    sourceRepository: String? = nil,
    destinationRepository: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.actor = actor
    self.eventKind = eventKind
    self.label = label
    self.labelColor = labelColor
    self.milestoneTitle = milestoneTitle
    self.oldTitle = oldTitle
    self.newTitle = newTitle
    self.sourceURL = sourceURL
    self.sourceTitle = sourceTitle
    self.sourceNumber = sourceNumber
    self.branchName = branchName
    self.beforeOid = beforeOid
    self.afterOid = afterOid
    self.lockReason = lockReason
    self.dismissalMessage = dismissalMessage
    self.requestedReviewerLogin = requestedReviewerLogin
    self.requestedReviewerTeamSlug = requestedReviewerTeamSlug
    self.assigneeLogin = assigneeLogin
    self.sourceRepository = sourceRepository
    self.destinationRepository = destinationRepository
  }

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt
    case actor
    case eventKind
    case label
    case labelColor
    case milestoneTitle
    case oldTitle
    case newTitle
    case sourceURL = "sourceUrl"
    case sourceTitle
    case sourceNumber
    case branchName
    case beforeOid
    case afterOid
    case lockReason
    case dismissalMessage
    case requestedReviewerLogin
    case requestedReviewerTeamSlug
    case assigneeLogin
    case sourceRepository
    case destinationRepository
  }
}
