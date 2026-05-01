import Foundation

struct WorkspaceDecisionDismissBatchSnapshot: Equatable {
  let ids: [String]
  let count: Int
  let filterSignature: String
  let scopeDescription: String
  let capturedAt: Date
}

struct WorkspaceDecisionReopenBatchState: Equatable {
  let ids: [String]
  let expiresAt: Date
}
