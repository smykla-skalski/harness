import Foundation

extension HarnessMonitorStore {
  func acpIdentityCrosswalk() -> AcpAgentIdentityCrosswalk {
    AcpAgentIdentityCrosswalk(
      selectedSessionIdentity: selectedSessionID.map(HarnessSessionID.init(rawValue:)),
      descriptorsByID: acpAgentDescriptorsByID,
      sessionRegistrations: selectedSession?.agents ?? [],
      snapshots: selectedAcpAgents,
      inspectSample: selectedAcpInspectState
    )
  }

  func acpIdentityCrosswalk(
    sessionID: String,
    sessionRegistrations: [AgentRegistration]
  ) -> AcpAgentIdentityCrosswalk {
    AcpAgentIdentityCrosswalk(
      selectedSessionIdentity: HarnessSessionID(rawValue: sessionID),
      descriptorsByID: acpAgentDescriptorsByID,
      sessionRegistrations: sessionRegistrations,
      snapshots: selectedAcpAgents.filter { $0.sessionId == sessionID },
      inspectSample: selectedAcpInspectState?.sessionID == sessionID ? selectedAcpInspectState : nil
    )
  }
}

extension AcpEventBatchPayload {
  var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: acpId)
  }
}

extension AcpConversationEvent {
  var sessionAgentIdentity: SessionAgentID? {
    let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    return SessionAgentID(rawValue: trimmed)
  }
}

extension HarnessMonitorStore {
  public func acpAgentSnapshot(for sessionAgentID: String) -> AcpAgentSnapshot? {
    acpAgentSnapshot(for: SessionAgentID(rawValue: sessionAgentID))
  }

  public func acpAgentSnapshot(
    for sessionAgentIdentity: SessionAgentID
  ) -> AcpAgentSnapshot? {
    acpIdentityCrosswalk()
      .agentLinkage(forSessionAgentIdentity: sessionAgentIdentity)?
      .snapshot
  }

  func acpAgentSnapshot(
    forManagedAgentIdentity managedAgentIdentity: ManagedAgentID
  ) -> AcpAgentSnapshot? {
    acpIdentityCrosswalk()
      .agentLinkage(forManagedAgentIdentity: managedAgentIdentity)?
      .snapshot
  }

  public func acpInspectSnapshot(for sessionAgentID: String) -> AcpAgentInspectSnapshot? {
    acpInspectSnapshot(for: SessionAgentID(rawValue: sessionAgentID))
  }

  public func acpInspectSnapshot(
    for sessionAgentIdentity: SessionAgentID
  ) -> AcpAgentInspectSnapshot? {
    acpIdentityCrosswalk()
      .agentLinkage(forSessionAgentIdentity: sessionAgentIdentity)?
      .inspect
  }

  public func acpRuntimeState(for sessionAgentID: String) -> AcpAgentRuntimeState? {
    acpRuntimeState(for: SessionAgentID(rawValue: sessionAgentID))
  }

  public func acpRuntimeState(
    for sessionAgentID: String,
    sessionID: String,
    sessionRegistrations: [AgentRegistration]
  ) -> AcpAgentRuntimeState? {
    acpRuntimeState(
      for: SessionAgentID(rawValue: sessionAgentID),
      sessionID: sessionID,
      sessionRegistrations: sessionRegistrations
    )
  }

  public func acpRuntimeState(
    for sessionAgentIdentity: SessionAgentID
  ) -> AcpAgentRuntimeState? {
    let linkage = acpIdentityCrosswalk().agentLinkage(
      forSessionAgentIdentity: sessionAgentIdentity
    )
    return AcpAgentRuntimeState(
      snapshot: linkage?.snapshot,
      inspect: linkage?.inspect,
      inspectSampledAt: selectedAcpInspectState?.sampledAt
    )
  }

  public func acpRuntimeState(
    for sessionAgentIdentity: SessionAgentID,
    sessionID: String,
    sessionRegistrations: [AgentRegistration]
  ) -> AcpAgentRuntimeState? {
    let inspectSample =
      selectedAcpInspectState?.sessionID == sessionID ? selectedAcpInspectState : nil
    let linkage = acpIdentityCrosswalk(
      sessionID: sessionID,
      sessionRegistrations: sessionRegistrations
    ).agentLinkage(forSessionAgentIdentity: sessionAgentIdentity)
    return AcpAgentRuntimeState(
      snapshot: linkage?.snapshot,
      inspect: linkage?.inspect,
      inspectSampledAt: inspectSample?.sampledAt
    )
  }

  public func acpRuntimeState(
    for sessionAgentIdentity: SessionAgentID,
    sessionID: String,
    sessionRegistrations: [AgentRegistration],
    snapshots: [AcpAgentSnapshot],
    inspectSample: AcpInspectSample?
  ) -> AcpAgentRuntimeState? {
    let linkage = AcpAgentIdentityCrosswalk(
      selectedSessionIdentity: HarnessSessionID(rawValue: sessionID),
      descriptorsByID: acpAgentDescriptorsByID,
      sessionRegistrations: sessionRegistrations,
      snapshots: snapshots,
      inspectSample: inspectSample?.sessionID == sessionID ? inspectSample : nil
    ).agentLinkage(forSessionAgentIdentity: sessionAgentIdentity)
    return AcpAgentRuntimeState(
      snapshot: linkage?.snapshot,
      inspect: linkage?.inspect,
      inspectSampledAt: inspectSample?.sampledAt
    )
  }

  func acpRuntimeState(
    forManagedAgentIdentity managedAgentIdentity: ManagedAgentID
  ) -> AcpAgentRuntimeState? {
    let linkage = acpIdentityCrosswalk().agentLinkage(
      forManagedAgentIdentity: managedAgentIdentity
    )
    return AcpAgentRuntimeState(
      snapshot: linkage?.snapshot,
      inspect: linkage?.inspect,
      inspectSampledAt: selectedAcpInspectState?.sampledAt
    )
  }
}
