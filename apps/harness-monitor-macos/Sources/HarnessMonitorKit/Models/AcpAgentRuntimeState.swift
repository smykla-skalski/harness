import Foundation

public struct AcpRuntimeIdentity: Equatable, Hashable, Identifiable, Sendable {
  public let sessionID: String
  public let acpID: String
  public let agentID: String

  public init(sessionID: String, acpID: String, agentID: String) {
    self.sessionID = sessionID
    self.acpID = acpID
    self.agentID = agentID
  }

  public init(snapshot: AcpAgentSnapshot) {
    self.init(
      sessionID: snapshot.sessionId,
      acpID: snapshot.acpId,
      agentID: snapshot.agentId
    )
  }

  public init(inspect: AcpAgentInspectSnapshot) {
    self.init(
      sessionID: inspect.sessionId,
      acpID: inspect.acpId,
      agentID: inspect.agentId
    )
  }

  public var id: String {
    "runtime.\(Self.idComponent(sessionID)).\(Self.idComponent(acpID)).\(Self.idComponent(agentID))"
  }

  private static func idComponent(_ value: String) -> String {
    Data(value.utf8).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }
}

public struct AcpInspectSample: Equatable, Sendable {
  public let sessionID: String
  public let sampledAt: Date

  private let orderedIdentities: [AcpRuntimeIdentity]
  private let snapshotsByIdentity: [AcpRuntimeIdentity: AcpAgentInspectSnapshot]

  public init(sessionID: String, sampledAt: Date, agents: [AcpAgentInspectSnapshot]) {
    self.sessionID = sessionID
    self.sampledAt = sampledAt

    var orderedIdentities: [AcpRuntimeIdentity] = []
    var snapshotsByIdentity: [AcpRuntimeIdentity: AcpAgentInspectSnapshot] = [:]

    for snapshot in agents where snapshot.sessionId == sessionID {
      let identity = AcpRuntimeIdentity(inspect: snapshot)
      if snapshotsByIdentity.updateValue(snapshot, forKey: identity) == nil {
        orderedIdentities.append(identity)
      }
    }

    self.orderedIdentities = orderedIdentities
    self.snapshotsByIdentity = snapshotsByIdentity
  }

  public var agents: [AcpAgentInspectSnapshot] {
    orderedIdentities.compactMap { snapshotsByIdentity[$0] }
  }

  func snapshot(for identity: AcpRuntimeIdentity) -> AcpAgentInspectSnapshot? {
    snapshotsByIdentity[identity]
  }

  func uniqueSnapshot(forAgentID agentID: String) -> AcpAgentInspectSnapshot? {
    let matchingIdentities = orderedIdentities.filter { $0.agentID == agentID }
    guard matchingIdentities.count == 1, let identity = matchingIdentities.first else {
      return nil
    }
    return snapshotsByIdentity[identity]
  }

  func filtered(keeping identities: Set<AcpRuntimeIdentity>) -> AcpInspectSample {
    AcpInspectSample(
      sessionID: sessionID,
      sampledAt: sampledAt,
      agents: orderedIdentities.compactMap { identity in
        guard identities.contains(identity) else {
          return nil
        }
        return snapshotsByIdentity[identity]
      }
    )
  }

  func filtered(removingMatching shouldRemove: (AcpRuntimeIdentity) -> Bool) -> AcpInspectSample {
    AcpInspectSample(
      sessionID: sessionID,
      sampledAt: sampledAt,
      agents: orderedIdentities.compactMap { identity in
        guard shouldRemove(identity) == false else {
          return nil
        }
        return snapshotsByIdentity[identity]
      }
    )
  }
}

public struct AcpAgentRuntimeState: Equatable, Identifiable, Sendable {
  public let identity: AcpRuntimeIdentity
  public let snapshot: AcpAgentSnapshot?
  public let inspect: AcpAgentInspectSnapshot?
  public let inspectSampledAt: Date?

  public init?(
    snapshot: AcpAgentSnapshot?,
    inspect: AcpAgentInspectSnapshot?,
    inspectSampledAt: Date?
  ) {
    guard snapshot != nil || inspect != nil else {
      return nil
    }

    let identity: AcpRuntimeIdentity
    if let snapshot, let inspect {
      let snapshotIdentity = AcpRuntimeIdentity(snapshot: snapshot)
      let inspectIdentity = AcpRuntimeIdentity(inspect: inspect)
      guard snapshotIdentity == inspectIdentity else {
        return nil
      }
      identity = snapshotIdentity
    } else if let snapshot {
      identity = AcpRuntimeIdentity(snapshot: snapshot)
    } else if let inspect {
      identity = AcpRuntimeIdentity(inspect: inspect)
    } else {
      return nil
    }

    self.identity = identity
    self.snapshot = snapshot
    self.inspect = inspect
    self.inspectSampledAt = inspect == nil ? nil : inspectSampledAt
  }

  public var id: String {
    identity.id
  }

  public var sessionId: String {
    identity.sessionID
  }

  public var agentId: String {
    identity.agentID
  }

  public var acpId: String {
    identity.acpID
  }

  public var agentName: String {
    inspect?.displayName ?? snapshot?.displayName ?? agentId
  }

  public var projectDir: String? {
    snapshot?.projectDir
  }

  public var pendingPermissions: Int {
    inspect?.pendingPermissions ?? snapshot?.pendingPermissions ?? 0
  }

  public var permissionQueueDepth: Int {
    inspect?.permissionQueueDepth ?? snapshot?.permissionQueueDepth ?? 0
  }

  public var terminalCount: Int {
    inspect?.terminalCount ?? snapshot?.terminalCount ?? 0
  }

  public var watchdogState: String? {
    inspect?.watchdogState
  }

  public var watchdogDisplayState: String {
    watchdogState ?? "syncing"
  }

  public var pid: UInt32? {
    inspect?.pid ?? snapshot?.pid
  }

  public var pgid: Int32? {
    inspect?.pgid ?? snapshot?.pgid
  }

  public var uptimeMs: UInt64? {
    inspect?.uptimeMs
  }

  public var lastUpdateAt: String? {
    inspect?.lastUpdateAt ?? snapshot?.updatedAt
  }

  public var lastClientCallAt: String? {
    inspect?.lastClientCallAt
  }

  public var promptDeadlineRemainingMs: UInt64? {
    guard let inspect, inspect.promptDeadlineRemainingMs > 0 else {
      return nil
    }
    return inspect.promptDeadlineRemainingMs
  }

  public var promptDeadlineAnchorAt: Date? {
    guard promptDeadlineRemainingMs != nil else {
      return nil
    }
    return inspectSampledAt
  }

  public var hasInspect: Bool {
    inspect != nil
  }
}
