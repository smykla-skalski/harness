import Foundation

public struct AcpDecisionAttention: Equatable, Sendable {
  public let count: Int
  public let oldestBatchID: String

  public init(count: Int, oldestBatchID: String) {
    self.count = count
    self.oldestBatchID = oldestBatchID
  }
}

extension HarnessMonitorStore {
  public func acpDecisionAttention(for agentID: String) -> AcpDecisionAttention? {
    guard let snapshot = selectedAcpAgents.first(where: { $0.agentId == agentID }) else {
      return nil
    }
    guard let oldestBatch = snapshot.pendingPermissionBatches.first else {
      return nil
    }
    let count = snapshot.pendingPermissionBatches.reduce(into: 0) { partialResult, batch in
      partialResult += batch.requests.count
    }
    guard count > 0 else {
      return nil
    }
    return AcpDecisionAttention(count: count, oldestBatchID: oldestBatch.batchId)
  }

  @discardableResult
  public func selectOldestDecision(for agentID: String) -> String? {
    let selectedID =
      supervisorOpenDecisions
      .filter { $0.agentID == agentID }
      .min { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
      }?
      .id
    supervisorSelectedDecisionID = selectedID
    return selectedID
  }
}
