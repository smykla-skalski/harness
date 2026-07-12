import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension MobileCommandRecord {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandRecord {
    var command = self
    command.title = redactor.redact(command.title)
    command.confirmationText = redactor.redact(command.confirmationText)
    command.auditReason = command.auditReason.map { redactor.redact($0) }
    command.payload = command.payload.mapValues { redactor.redact($0) }
    command.receipt = command.receipt?.redactingMobileMirrorSecrets(using: redactor)
    return command
  }
}

extension MobileCommandReceipt {
  func redactingMobileMirrorSecrets(
    using redactor: MobileMirrorSecretRedactor
  ) -> MobileCommandReceipt {
    var receipt = self
    receipt.message = redactor.redact(receipt.message)
    return receipt
  }
}

struct MobileRelayTaskBoardFetchResult: Sendable {
  var items: [TaskBoardItem]
  var mobileItems: [MobileTaskBoardSummary]?
  var attentionFallback: [MobileAttentionItem]

  init(
    items: [TaskBoardItem],
    mobileItems: [MobileTaskBoardSummary]? = nil,
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.items = items
    self.mobileItems = mobileItems
    self.attentionFallback = attentionFallback
  }
}

struct MobileRelaySessionDetailFetchResult: Sendable {
  var detailsBySessionID: [String: SessionDetail]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

struct MobileRelaySessionDetailFetchOutcome: Sendable {
  var sessionID: String
  var detail: SessionDetail?
}

struct MobileRelayManagedAgentsFetchResult: Sendable {
  var agentsBySessionID: [String: [ManagedAgentSnapshot]]
  var failedSessionIDs: Set<String>
  var attentionFallback: [MobileAttentionItem]
}

struct MobileRelayManagedAgentsFetchOutcome: Sendable {
  var sessionID: String
  var agents: [ManagedAgentSnapshot]?
}

extension ManagedAgentSnapshot {
  var displayTitle: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.agentId
    case .codex(let snapshot):
      snapshot.displayName ?? snapshot.runId
    case .acp(let snapshot):
      snapshot.displayName
    }
  }
}

struct MobileRelayReviewFetchResult: Sendable {
  var reviews: [ReviewItem]
  var mobileReviews: [MobileReviewSummary]
  var attentionFallback: [MobileAttentionItem]

  init(
    reviews: [ReviewItem],
    mobileReviews: [MobileReviewSummary],
    attentionFallback: [MobileAttentionItem] = []
  ) {
    self.reviews = reviews
    self.mobileReviews = mobileReviews
    self.attentionFallback = attentionFallback
  }
}

struct MobileRelaySnapshotBuildInput: Sendable {
  var now: Date
  var revision: Int64
  var health: HealthResponse
  var sessions: [SessionSummary]
  var sessionDetailFetch: MobileRelaySessionDetailFetchResult
  var managedAgentsFetch: MobileRelayManagedAgentsFetchResult
  var reviewFetch: MobileRelayReviewFetchResult
  var taskBoardFetch: MobileRelayTaskBoardFetchResult
  var trustedDevices: [MobileDeviceDescriptor]
}

struct MobileRelayReviewEnrichment: Sendable {
  var review: ReviewItem
  var filesResponse: ReviewsFilesListResponse?
  var timelineResponse: ReviewsTimelineResponse?
}

func batches<Element>(_ values: [Element], size: Int) -> [[Element]] {
  guard size > 0, !values.isEmpty else {
    return []
  }
  var result: [[Element]] = []
  result.reserveCapacity((values.count + size - 1) / size)
  var start = values.startIndex
  while start < values.endIndex {
    let end = values.index(start, offsetBy: size, limitedBy: values.endIndex) ?? values.endIndex
    result.append(Array(values[start..<end]))
    start = end
  }
  return result
}
