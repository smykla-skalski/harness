import Foundation

extension HarnessMonitorStore {
  func makeAcpPermissionDecisionPayload(
    for batch: AcpPermissionBatch
  ) -> AcpPermissionDecisionPayload {
    if let snapshot = selectedAcpAgents.first(where: { $0.acpId == batch.acpId }) {
      return AcpPermissionDecisionPayload.make(
        batch: batch,
        agentID: snapshot.agentId,
        agentName: snapshot.displayName
      )
    }
    return AcpPermissionDecisionPayload.make(
      batch: batch,
      agentID: batch.acpId,
      agentName: batch.acpId
    )
  }

  func resolveAcpPermissionPayload(
    decisionID: String,
    decisionStore: DecisionStore?
  ) async throws -> AcpPermissionDecisionPayload? {
    if let payload = acpPermissionPayloadsByDecisionID[decisionID] {
      return payload
    }
    guard let decisionStore else {
      return nil
    }
    guard let decision = try await decisionStore.decision(id: decisionID) else {
      return nil
    }
    guard let payload = AcpPermissionDecisionPayload.decode(from: decision) else {
      return nil
    }
    acpPermissionPayloadsByDecisionID[decisionID] = payload
    if acpPermissionResolutionStateByDecisionID[decisionID] == nil {
      acpPermissionResolutionStateByDecisionID[decisionID] = payload.defaultResolutionState
    }
    return payload
  }

  func markAcpPermissionDecisionSubmission(
    decisionID: String,
    submittedAt: Date?
  ) {
    guard
      var state = acpPermissionResolutionStateByDecisionID[decisionID]
        ?? acpPermissionPayloadsByDecisionID[decisionID]?.defaultResolutionState
    else {
      return
    }
    state.submittedAt = submittedAt
    acpPermissionResolutionStateByDecisionID[decisionID] = state
  }

  func removeAcpPermissionDecisionArtifacts(decisionID: String) {
    acpPermissionPayloadsByDecisionID.removeValue(forKey: decisionID)
    acpPermissionResolutionStateByDecisionID.removeValue(forKey: decisionID)
  }
}
