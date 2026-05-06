import Foundation

extension HarnessMonitorStore {
  func makeAcpPermissionDecisionPayload(
    for batch: AcpPermissionBatch
  ) -> AcpPermissionDecisionPayload {
    let linkage = acpIdentityCrosswalk().agentLinkage(
      forManagedAgentIdentity: batch.managedAgentIdentity
    )
    return AcpPermissionDecisionPayload.make(
      batch: batch,
      agentID: linkage?.explicitSessionAgentLookupKey
        ?? AcpAgentIdentityCrosswalk.explicitSessionAgentFallbackKey(
          for: batch.managedAgentIdentity
        ),
      agentName: linkage?.explicitDisplayName
        ?? AcpAgentIdentityCrosswalk.unresolvedDisplayName(for: batch.managedAgentIdentity)
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
