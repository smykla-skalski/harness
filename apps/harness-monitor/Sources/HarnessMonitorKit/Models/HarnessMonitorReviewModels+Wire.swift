import Foundation

// Wire maps for the review-flow types nested inside WorkItem (awaiting review, claim, consensus,
// arbitration). ReviewVerdict and ReviewPoint/ReviewPointState are decoder-agnostic and ride
// through bare; the UInt8 consensus count narrows to Int.

extension AwaitingReview {
  init(wire: AwaitingReviewWire) {
    self.init(
      queuedAt: wire.queuedAt,
      submitterAgentId: wire.submitterAgentId,
      summary: wire.summary,
      requiredConsensus: Int(wire.requiredConsensus)
    )
  }
}

extension ReviewerEntry {
  init(wire: ReviewerEntryWire) {
    self.init(
      reviewerAgentId: wire.reviewerAgentId,
      reviewerRuntime: wire.reviewerRuntime,
      claimedAt: wire.claimedAt,
      submittedAt: wire.submittedAt
    )
  }
}

extension ReviewClaim {
  init(wire: ReviewClaimWire) {
    self.init(reviewers: wire.reviewers.map(ReviewerEntry.init(wire:)))
  }
}

extension ReviewConsensus {
  init(wire: ReviewConsensusWire) {
    self.init(
      verdict: wire.verdict,
      summary: wire.summary,
      points: wire.points,
      closedAt: wire.closedAt,
      reviewerAgentIds: wire.reviewerAgentIds
    )
  }
}

extension ArbitrationOutcome {
  init(wire: ArbitrationOutcomeWire) {
    self.init(
      arbiterAgentId: wire.arbiterAgentId,
      verdict: wire.verdict,
      summary: wire.summary,
      recordedAt: wire.recordedAt
    )
  }
}
