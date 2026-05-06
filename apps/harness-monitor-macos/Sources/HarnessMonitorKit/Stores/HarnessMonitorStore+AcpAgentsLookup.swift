import Foundation

struct AcpDescriptorIdentityLinkage: Equatable, Sendable {
  let descriptorIdentity: AcpDescriptorID
  let descriptor: AcpAgentDescriptor

  init(descriptor: AcpAgentDescriptor) {
    descriptorIdentity = descriptor.descriptorIdentity
    self.descriptor = descriptor
  }

  var displayName: String {
    descriptor.displayName
  }

  var capabilityTags: [String] {
    descriptor.capabilities
  }
}

struct AcpAgentIdentityLinkage: Equatable, Sendable {
  let sessionIdentity: HarnessSessionID
  let descriptorIdentity: AcpDescriptorID?
  let sessionAgentIdentity: SessionAgentID?
  let managedAgentIdentity: ManagedAgentID
  let runtimeSessionIdentity: RuntimeSessionID?
  let displayName: String
  let capabilityTags: [String]
  let snapshot: AcpAgentSnapshot?
  let inspect: AcpAgentInspectSnapshot?
  let registration: AgentRegistration?
  let descriptor: AcpAgentDescriptor?

  var explicitSessionAgentLookupKey: String {
    sessionAgentIdentity?.rawValue
      ?? AcpAgentIdentityCrosswalk.explicitSessionAgentFallbackKey(for: managedAgentIdentity)
  }

  var explicitDisplayName: String {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      ? AcpAgentIdentityCrosswalk.unresolvedDisplayName(for: managedAgentIdentity)
      : trimmed
  }
}

private enum AcpAgentIdentityLookupResult {
  case unique(AcpAgentIdentityLinkage)
  case ambiguous
}

struct AcpAgentIdentityCrosswalk {
  private struct BuildInputs {
    let selectedSessionIdentity: HarnessSessionID?
    let descriptorLinkagesByIdentity: [AcpDescriptorID: AcpDescriptorIdentityLinkage]
    let registrationsByManagedAgentIdentity: [ManagedAgentID: AgentRegistration]
    let registrationsBySessionAgentIdentity: [SessionAgentID: [AgentRegistration]]
    let snapshotsByManagedAgentIdentity: [ManagedAgentID: AcpAgentSnapshot]
    let inspectByManagedAgentIdentity: [ManagedAgentID: AcpAgentInspectSnapshot]
  }

  private let descriptorLinkagesByIdentity: [AcpDescriptorID: AcpDescriptorIdentityLinkage]
  private let linkagesByManagedAgentIdentity: [ManagedAgentID: AcpAgentIdentityLinkage]
  private let linkagesBySessionAgentIdentity: [SessionAgentID: AcpAgentIdentityLookupResult]
  private let linkagesByRuntimeSessionIdentity: [RuntimeSessionID: AcpAgentIdentityLookupResult]

  init(
    selectedSessionIdentity: HarnessSessionID?,
    descriptorsByID: [String: AcpAgentDescriptor],
    sessionRegistrations: [AgentRegistration],
    snapshots: [AcpAgentSnapshot],
    inspectSample: AcpInspectSample?
  ) {
    let descriptorLinkagesByIdentity = Dictionary(
      uniqueKeysWithValues: descriptorsByID.values.map { descriptor in
        (descriptor.descriptorIdentity, AcpDescriptorIdentityLinkage(descriptor: descriptor))
      }
    )

    let registrationsByManagedAgentIdentity = Self.registrationsByManagedAgentIdentity(
      from: sessionRegistrations
    )
    let registrationsBySessionAgentIdentity = Dictionary(
      grouping: sessionRegistrations,
      by: \.sessionAgentIdentity
    )
    let snapshotsByManagedAgentIdentity = Dictionary(
      uniqueKeysWithValues: snapshots.map { ($0.managedAgentIdentity, $0) }
    )
    let inspectByManagedAgentIdentity = Dictionary(
      uniqueKeysWithValues: (inspectSample?.agents ?? []).map { ($0.managedAgentIdentity, $0) }
    )

    let linkagesByManagedAgentIdentity = Self.buildLinkages(
      inputs: BuildInputs(
        selectedSessionIdentity: selectedSessionIdentity,
        descriptorLinkagesByIdentity: descriptorLinkagesByIdentity,
        registrationsByManagedAgentIdentity: registrationsByManagedAgentIdentity,
        registrationsBySessionAgentIdentity: registrationsBySessionAgentIdentity,
        snapshotsByManagedAgentIdentity: snapshotsByManagedAgentIdentity,
        inspectByManagedAgentIdentity: inspectByManagedAgentIdentity
      )
    )

    self.descriptorLinkagesByIdentity = descriptorLinkagesByIdentity
    self.linkagesByManagedAgentIdentity = linkagesByManagedAgentIdentity
    linkagesBySessionAgentIdentity = Self.uniqueLookupTable(
      linkagesByManagedAgentIdentity.values,
      keyPath: \.sessionAgentIdentity
    )
    linkagesByRuntimeSessionIdentity = Self.uniqueLookupTable(
      linkagesByManagedAgentIdentity.values,
      keyPath: \.runtimeSessionIdentity
    )
  }

  func descriptorLinkage(
    for descriptorIdentity: AcpDescriptorID
  ) -> AcpDescriptorIdentityLinkage? {
    descriptorLinkagesByIdentity[descriptorIdentity]
  }

  func agentLinkage(
    forManagedAgentIdentity managedAgentIdentity: ManagedAgentID
  ) -> AcpAgentIdentityLinkage? {
    linkagesByManagedAgentIdentity[managedAgentIdentity]
  }

  func agentLinkage(
    forSessionAgentIdentity sessionAgentIdentity: SessionAgentID
  ) -> AcpAgentIdentityLinkage? {
    uniqueLinkage(for: linkagesBySessionAgentIdentity[sessionAgentIdentity])
  }

  func agentLinkage(
    forRuntimeSessionIdentity runtimeSessionIdentity: RuntimeSessionID
  ) -> AcpAgentIdentityLinkage? {
    uniqueLinkage(for: linkagesByRuntimeSessionIdentity[runtimeSessionIdentity])
  }

  static func explicitSessionAgentFallbackKey(
    for managedAgentIdentity: ManagedAgentID
  ) -> String {
    "managed:\(managedAgentIdentity.rawValue)"
  }

  static func isExplicitSessionAgentFallbackKey(_ value: String) -> Bool {
    value.hasPrefix("managed:")
  }

  static func unresolvedDisplayName(
    for managedAgentIdentity: ManagedAgentID
  ) -> String {
    "ACP agent \(managedAgentIdentity.rawValue)"
  }

  private static func registrationsByManagedAgentIdentity(
    from sessionRegistrations: [AgentRegistration]
  ) -> [ManagedAgentID: AgentRegistration] {
    Dictionary(
      uniqueKeysWithValues: sessionRegistrations.compactMap { registration in
        guard registration.managedAgent?.kind == .acp,
          let managedAgentIdentity = registration.managedAgentIdentity
        else {
          return nil
        }
        return (managedAgentIdentity, registration)
      }
    )
  }

  private static func buildLinkages(
    inputs: BuildInputs
  ) -> [ManagedAgentID: AcpAgentIdentityLinkage] {
    let managedAgentIdentities = Set(inputs.snapshotsByManagedAgentIdentity.keys)
      .union(inputs.inspectByManagedAgentIdentity.keys)
      .union(inputs.registrationsByManagedAgentIdentity.keys)

    var linkagesByManagedAgentIdentity: [ManagedAgentID: AcpAgentIdentityLinkage] = [:]
    linkagesByManagedAgentIdentity.reserveCapacity(managedAgentIdentities.count)

    for managedAgentIdentity in managedAgentIdentities {
      let snapshot = inputs.snapshotsByManagedAgentIdentity[managedAgentIdentity]
      let inspect = compatibleInspect(
        inputs.inspectByManagedAgentIdentity[managedAgentIdentity],
        for: snapshot
      )
      let preferredSessionAgentIdentity =
        snapshot?.sessionAgentIdentity
        ?? inspect?.sessionAgentIdentity
      let registration = compatibleRegistration(
        managedAgentIdentity: managedAgentIdentity,
        preferredSessionAgentIdentity: preferredSessionAgentIdentity,
        registrationsByManagedAgentIdentity: inputs.registrationsByManagedAgentIdentity,
        registrationsBySessionAgentIdentity: inputs.registrationsBySessionAgentIdentity,
        descriptorLinkagesByIdentity: inputs.descriptorLinkagesByIdentity
      )
      let sessionIdentity =
        snapshot?.sessionIdentity
        ?? inspect?.sessionIdentity
        ?? inputs.selectedSessionIdentity
      guard let sessionIdentity else {
        continue
      }
      let sessionAgentIdentity = preferredSessionAgentIdentity ?? registration?.sessionAgentIdentity
      let descriptorLinkage =
        registration.flatMap { registration in
          inputs.descriptorLinkagesByIdentity[AcpDescriptorID(rawValue: registration.runtime)]
        }
        ?? sessionAgentIdentity.flatMap { sessionAgentIdentity in
          inputs.descriptorLinkagesByIdentity[
            AcpDescriptorID(rawValue: sessionAgentIdentity.rawValue)]
        }
      let displayName =
        snapshot?.displayName
        ?? inspect?.displayName
        ?? registration?.name
        ?? descriptorLinkage?.displayName
        ?? unresolvedDisplayName(for: managedAgentIdentity)

      linkagesByManagedAgentIdentity[managedAgentIdentity] = AcpAgentIdentityLinkage(
        sessionIdentity: sessionIdentity,
        descriptorIdentity: descriptorLinkage?.descriptorIdentity,
        sessionAgentIdentity: sessionAgentIdentity,
        managedAgentIdentity: managedAgentIdentity,
        runtimeSessionIdentity: registration?.runtimeSessionIdentity,
        displayName: displayName,
        capabilityTags: descriptorLinkage?.capabilityTags ?? registration?.capabilities ?? [],
        snapshot: snapshot,
        inspect: inspect,
        registration: registration,
        descriptor: descriptorLinkage?.descriptor
      )
    }

    return linkagesByManagedAgentIdentity
  }

  private static func compatibleInspect(
    _ inspect: AcpAgentInspectSnapshot?,
    for snapshot: AcpAgentSnapshot?
  ) -> AcpAgentInspectSnapshot? {
    guard let inspect else {
      return nil
    }
    guard let snapshot else {
      return inspect
    }
    guard snapshot.sessionIdentity == inspect.sessionIdentity,
      snapshot.sessionAgentIdentity == inspect.sessionAgentIdentity
    else {
      return nil
    }
    return inspect
  }

  private static func compatibleRegistration(
    managedAgentIdentity: ManagedAgentID,
    preferredSessionAgentIdentity: SessionAgentID?,
    registrationsByManagedAgentIdentity: [ManagedAgentID: AgentRegistration],
    registrationsBySessionAgentIdentity: [SessionAgentID: [AgentRegistration]],
    descriptorLinkagesByIdentity: [AcpDescriptorID: AcpDescriptorIdentityLinkage]
  ) -> AgentRegistration? {
    if let registration = registrationsByManagedAgentIdentity[managedAgentIdentity],
      preferredSessionAgentIdentity == nil
        || registration.sessionAgentIdentity == preferredSessionAgentIdentity
    {
      return registration
    }
    guard let preferredSessionAgentIdentity,
      let registrations = registrationsBySessionAgentIdentity[preferredSessionAgentIdentity]
    else {
      return nil
    }
    let candidates = registrations.filter { registration in
      if registration.managedAgent?.kind == .acp {
        return true
      }
      guard registration.managedAgent == nil else {
        return false
      }
      return descriptorLinkagesByIdentity[AcpDescriptorID(rawValue: registration.runtime)] != nil
    }
    guard candidates.count == 1 else {
      return nil
    }
    return candidates[0]
  }

  private static func uniqueLookupTable<Key: Hashable>(
    _ linkages: Dictionary<ManagedAgentID, AcpAgentIdentityLinkage>.Values,
    keyPath: KeyPath<AcpAgentIdentityLinkage, Key?>
  ) -> [Key: AcpAgentIdentityLookupResult] {
    let grouped = Dictionary(
      grouping: linkages.compactMap { linkage -> (Key, AcpAgentIdentityLinkage)? in
        guard let key = linkage[keyPath: keyPath] else {
          return nil
        }
        return (key, linkage)
      },
      by: \.0
    )
    return grouped.mapValues { entries in
      guard entries.count == 1, let linkage = entries.first?.1 else {
        return .ambiguous
      }
      return .unique(linkage)
    }
  }

  private func uniqueLinkage(
    for lookupResult: AcpAgentIdentityLookupResult?
  ) -> AcpAgentIdentityLinkage? {
    guard case .unique(let linkage) = lookupResult else {
      return nil
    }
    return linkage
  }
}

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
