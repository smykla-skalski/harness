import Foundation

private enum AcpAgentSnapshotLookupResult {
  case none
  case unique(AcpAgentSnapshot)
  case ambiguous
}

extension HarnessMonitorStore {
  public func acpAgentSnapshot(for agentID: String) -> AcpAgentSnapshot? {
    guard case .unique(let snapshot) = acpAgentSnapshotLookup(for: agentID) else {
      return nil
    }
    return snapshot
  }

  public func acpInspectSnapshot(for agentID: String) -> AcpAgentInspectSnapshot? {
    selectedAcpInspectState?.uniqueSnapshot(forAgentID: agentID)
  }

  public func acpRuntimeState(for agentID: String) -> AcpAgentRuntimeState? {
    let snapshot: AcpAgentSnapshot?
    let inspect: AcpAgentInspectSnapshot?
    switch acpAgentSnapshotLookup(for: agentID) {
    case .ambiguous:
      return nil
    case .none:
      snapshot = nil
      inspect = selectedAcpInspectState?.uniqueSnapshot(forAgentID: agentID)
    case .unique(let resolvedSnapshot):
      snapshot = resolvedSnapshot
      inspect = selectedAcpInspectState?.snapshot(
        for: AcpRuntimeIdentity(snapshot: resolvedSnapshot))
    }
    return AcpAgentRuntimeState(
      snapshot: snapshot,
      inspect: inspect,
      inspectSampledAt: selectedAcpInspectState?.sampledAt
    )
  }

  private func acpAgentSnapshotLookup(for agentID: String) -> AcpAgentSnapshotLookupResult {
    var match: AcpAgentSnapshot?
    for snapshot in selectedAcpAgents where snapshot.agentId == agentID {
      guard match == nil else {
        return .ambiguous
      }
      match = snapshot
    }
    guard let match else {
      return .none
    }
    return .unique(match)
  }
}
