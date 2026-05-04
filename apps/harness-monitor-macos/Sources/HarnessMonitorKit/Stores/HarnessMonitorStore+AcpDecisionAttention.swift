import Foundation

public struct AcpDecisionAttention: Equatable, Sendable {
  public let count: Int
  public let oldestBatchID: String
  public let oldestDecisionID: String

  public init(count: Int, oldestBatchID: String, oldestDecisionID: String) {
    self.count = count
    self.oldestBatchID = oldestBatchID
    self.oldestDecisionID = oldestDecisionID
  }
}

public struct AcpDecisionAttentionSnapshot: Equatable, Sendable {
  public let byAgentID: [String: AcpDecisionAttention]

  public init(byAgentID: [String: AcpDecisionAttention]) {
    self.byAgentID = byAgentID
  }
}

extension HarnessMonitorStore {
  public func acpDecisionAttention(for agentID: String) -> AcpDecisionAttention? {
    acpDecisionAttentionSnapshot.byAgentID[agentID]
  }

  func rebuildAcpDecisionAttentionCache() {
    var byAgentID: [String: AcpDecisionAttention] = [:]
    var events: [AcpPermissionAttentionEvent] = []
    byAgentID.reserveCapacity(selectedAcpAgents.count)
    events.reserveCapacity(selectedAcpAgents.count)

    for snapshot in selectedAcpAgents {
      guard let summary = acpDecisionAttentionSummary(for: snapshot) else {
        continue
      }
      byAgentID[snapshot.agentId] = summary.attention
      events.append(
        AcpPermissionAttentionEvent(
          batchID: summary.attention.oldestBatchID,
          decisionID: summary.attention.oldestDecisionID,
          agentID: snapshot.agentId,
          agentName: snapshot.displayName,
          requestCount: summary.attention.count,
          createdAt: summary.createdAt
        )
      )
    }

    events.sort { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.batchID < rhs.batchID
    }

    acpDecisionAttentionSnapshot = AcpDecisionAttentionSnapshot(byAgentID: byAgentID)
    acpPermissionAttentionEvents = events
  }

  public func oldestDecisionID(for agentID: String) -> String? {
    acpDecisionAttentionSnapshot.byAgentID[agentID]?.oldestDecisionID
  }

  @discardableResult
  public func selectOldestDecision(for agentID: String) -> String? {
    let selectedID = oldestDecisionID(for: agentID)
    supervisorSelectedDecisionID = selectedID
    return selectedID
  }
}

private struct AcpDecisionAttentionSummary {
  let attention: AcpDecisionAttention
  let createdAt: String
}

extension HarnessMonitorStore {
  fileprivate func acpDecisionAttentionSummary(
    for snapshot: AcpAgentSnapshot
  ) -> AcpDecisionAttentionSummary? {
    var oldestBatch: AcpPermissionBatch?
    var requestCount = 0

    for batch in snapshot.pendingPermissionBatches {
      requestCount += batch.requests.count
      if let currentOldest = oldestBatch {
        if batch.createdAt < currentOldest.createdAt
          || (batch.createdAt == currentOldest.createdAt && batch.batchId < currentOldest.batchId)
        {
          oldestBatch = batch
        }
      } else {
        oldestBatch = batch
      }
    }

    guard requestCount > 0, let oldestBatch else {
      return nil
    }

    return AcpDecisionAttentionSummary(
      attention: AcpDecisionAttention(
        count: requestCount,
        oldestBatchID: oldestBatch.batchId,
        oldestDecisionID: acpPermissionDecisionID(for: oldestBatch.batchId)
      ),
      createdAt: oldestBatch.createdAt
    )
  }
}
