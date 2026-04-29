import Foundation

public struct AcpDecisionAttention: Equatable, Sendable {
  public let count: Int
  public let oldestBatchID: String

  public init(count: Int, oldestBatchID: String) {
    self.count = count
    self.oldestBatchID = oldestBatchID
  }
}

public struct AcpDecisionAttentionSnapshot: Equatable, Sendable {
  public let byAgentID: [String: AcpDecisionAttention]

  public init(byAgentID: [String: AcpDecisionAttention]) {
    self.byAgentID = byAgentID
  }
}

extension HarnessMonitorStore {
  /// Derived ACP attention for the currently selected session only.
  ///
  /// Freshness contract:
  /// - This is rebuilt directly from `selectedAcpAgents` on every read, so it cannot outlive the
  ///   store's selected-session ACP snapshot.
  /// - No background cache or independent invalidation path exists; replacing `selectedAcpAgents`
  ///   is the only way the attention model changes.
  ///
  /// Ordering contract:
  /// - `oldestBatchID` is selected by daemon-authored `(createdAt, batchId)` ordering to make the
  ///   oldest pending ACP batch deterministic when batches arrive in unstable array order.
  public var acpDecisionAttentionSnapshot: AcpDecisionAttentionSnapshot {
    var byAgentID: [String: AcpDecisionAttention] = [:]
    byAgentID.reserveCapacity(selectedAcpAgents.count)

    for snapshot in selectedAcpAgents {
      let sortedBatches = snapshot.pendingPermissionBatches.sorted {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.batchId < $1.batchId
      }
      guard let oldestBatch = sortedBatches.first else {
        continue
      }
      let count = sortedBatches.reduce(into: 0) { partialResult, batch in
        partialResult += batch.requests.count
      }
      guard count > 0 else {
        continue
      }
      byAgentID[snapshot.agentId] = AcpDecisionAttention(
        count: count,
        oldestBatchID: oldestBatch.batchId
      )
    }

    return AcpDecisionAttentionSnapshot(byAgentID: byAgentID)
  }

  public func acpDecisionAttention(for agentID: String) -> AcpDecisionAttention? {
    acpDecisionAttentionSnapshot.byAgentID[agentID]
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
