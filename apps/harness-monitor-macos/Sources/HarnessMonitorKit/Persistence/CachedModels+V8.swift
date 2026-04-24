import Foundation
import SwiftData

/// V8 introduces one additive side-table, `CachedTaskReviewMetadata`,
/// that stores the Slice 1 review workflow state (awaiting review,
/// reviewer claim, consensus, round counter, arbitration, persona hint,
/// review history) keyed by session and task. The main `CachedWorkItem`
/// class is left untouched so existing relationships stay stable. Old
/// rows simply lack a companion metadata row, which the conversion layer
/// interprets as an empty review block.
extension HarnessMonitorSchemaV8 {
  @Model
  final class CachedTaskReviewMetadata {
    #Index<CachedTaskReviewMetadata>([\.sessionId, \.taskId])
    #Unique<CachedTaskReviewMetadata>([\.sessionId, \.taskId])

    var sessionId: String
    var taskId: String
    var reviewBlob: Data
    var updatedAt: Date

    init(
      sessionId: String,
      taskId: String,
      reviewBlob: Data,
      updatedAt: Date = .now
    ) {
      self.sessionId = sessionId
      self.taskId = taskId
      self.reviewBlob = reviewBlob
      self.updatedAt = updatedAt
    }
  }
}

typealias CachedTaskReviewMetadata = HarnessMonitorSchemaV8.CachedTaskReviewMetadata

/// JSON payload persisted in `CachedTaskReviewMetadata.reviewBlob`. All
/// fields are optional/empty-default so rows with no stored metadata
/// decode to an empty review state.
struct CachedReviewMetadata: Codable, Equatable, Sendable {
  var awaitingReview: AwaitingReview?
  var reviewClaim: ReviewClaim?
  var consensus: ReviewConsensus?
  var reviewRound: Int = 0
  var arbitration: ArbitrationOutcome?
  var suggestedPersona: String?
  var reviewHistory: [ReviewConsensus] = []

  static let empty = Self()

  var isEmpty: Bool {
    awaitingReview == nil
      && reviewClaim == nil
      && consensus == nil
      && reviewRound == 0
      && arbitration == nil
      && suggestedPersona == nil
      && reviewHistory.isEmpty
  }

  init(
    awaitingReview: AwaitingReview? = nil,
    reviewClaim: ReviewClaim? = nil,
    consensus: ReviewConsensus? = nil,
    reviewRound: Int = 0,
    arbitration: ArbitrationOutcome? = nil,
    suggestedPersona: String? = nil,
    reviewHistory: [ReviewConsensus] = []
  ) {
    self.awaitingReview = awaitingReview
    self.reviewClaim = reviewClaim
    self.consensus = consensus
    self.reviewRound = reviewRound
    self.arbitration = arbitration
    self.suggestedPersona = suggestedPersona
    self.reviewHistory = reviewHistory
  }

  init(from item: WorkItem) {
    self.awaitingReview = item.awaitingReview
    self.reviewClaim = item.reviewClaim
    self.consensus = item.consensus
    self.reviewRound = item.reviewRound
    self.arbitration = item.arbitration
    self.suggestedPersona = item.suggestedPersona
    self.reviewHistory = item.reviewHistory
  }
}
