import Foundation

struct DecisionDismissBatchSnapshot: Equatable {
  let ids: [String]
  let count: Int
  let filterSignature: String
  let scopeDescription: String
  let capturedAt: Date
}

struct DecisionReopenBatchState: Equatable {
  let ids: [String]
  let expiresAt: Date
}
