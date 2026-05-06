import Foundation

/// One daemon-issued permission item inside an ACP batch.
///
/// UI-0 contract: approval granularity is request-level, but queue ownership is batch-level.
/// A future "approve some" audit row must preserve the chosen `requestId` subset exactly as
/// emitted here so resolution remains replayable without re-reading the original tool payload.
public struct AcpPermissionItem: Codable, Equatable, Sendable {
  public let requestId: String
  public let sessionId: String
  public let toolCall: JSONValue
  public let options: [JSONValue]
}

/// First-class ACP permission queue element.
///
/// UI-0 contract:
/// - One batch carries `1...N` `requests`; "approve some" is therefore a partial resolution of a
///   single queue item, not multiple queue items.
/// - `batchId` is the idempotency key for every UI/store mutation. Replays with the same
///   `batchId` refresh the payload in place instead of creating a second pending row.
/// - `createdAt` is daemon-authored ordering data. When the UI later renders decisions instead of
///   the modal, sticky selection must keep the currently focused batch while preserving this
///   oldest-first queue order for newly materialised rows.
/// - `expiresAt` is the daemon-authored absolute permission deadline. Countdown and expiry UI must
///   derive from this field instead of re-creating a local deadline from `createdAt`.
public struct AcpPermissionBatch: Codable, Equatable, Identifiable, Sendable {
  public let batchId: String
  public let acpId: String
  public let sessionId: String
  public let requests: [AcpPermissionItem]
  public let createdAt: String
  public let expiresAt: String?

  public init(
    batchId: String,
    acpId: String,
    sessionId: String,
    requests: [AcpPermissionItem],
    createdAt: String,
    expiresAt: String? = nil
  ) {
    self.batchId = batchId
    self.acpId = acpId
    self.sessionId = sessionId
    self.requests = requests
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  public var id: String { batchId }
  public var managedAgentID: String { acpId }

  private enum CodingKeys: String, CodingKey {
    case batchId
    case acpId
    case managedAgentId
    case managedAgentFamily
    case sessionId
    case requests
    case createdAt
    case expiresAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    batchId = try container.decode(String.self, forKey: .batchId)
    acpId =
      try container.decodeIfPresent(String.self, forKey: .managedAgentId)
      ?? container.decode(String.self, forKey: .acpId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    requests = try container.decode([AcpPermissionItem].self, forKey: .requests)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(batchId, forKey: .batchId)
    try container.encode(acpId, forKey: .acpId)
    try container.encode(acpId, forKey: .managedAgentId)
    try container.encode("acp", forKey: .managedAgentFamily)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(requests, forKey: .requests)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
  }
}

/// Canonical outcome semantics for ACP permission resolution.
///
/// UI-0 contract:
/// - Exactly one terminal decision is emitted per `batchId`.
/// - `.approveAll` and `.denyAll` are whole-batch terminals.
/// - `.approveSome` embeds the exact approved `requestId` array and implies deny for every
///   request in the batch not listed there.
/// - Timeout and daemon-shutdown removals are not enum cases here. They arrive through the daemon
///   removal event stream and belong in queue/audit handling rather than the decision payload.
public enum AcpPermissionDecision: Codable, Equatable, Sendable {
  case approveAll
  case approveSome([String])
  case denyAll

  private enum CodingKeys: String, CodingKey {
    case decision
    case requestIds
  }

  private enum Decision: String, Codable {
    case approveAll = "approve_all"
    case approveSome = "approve_some"
    case denyAll = "deny_all"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Decision.self, forKey: .decision) {
    case .approveAll:
      self = .approveAll
    case .approveSome:
      self = .approveSome(try container.decode([String].self, forKey: .requestIds))
    case .denyAll:
      self = .denyAll
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .approveAll:
      try container.encode(Decision.approveAll, forKey: .decision)
    case .approveSome(let requestIDs):
      try container.encode(Decision.approveSome, forKey: .decision)
      try container.encode(requestIDs, forKey: .requestIds)
    case .denyAll:
      try container.encode(Decision.denyAll, forKey: .decision)
    }
  }
}

public struct AcpAgentSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let acpId: String
  public let sessionId: String
  public let agentId: String
  public let displayName: String
  public let status: AgentStatus
  public let pid: UInt32
  public let pgid: Int32
  public let projectDir: String
  public let pendingPermissions: Int
  public let permissionQueueDepth: Int
  public let pendingPermissionBatches: [AcpPermissionBatch]
  public let terminalCount: Int
  public let createdAt: String
  public let updatedAt: String
  public let disconnectReason: AgentDisconnectReason?
  public let stderrTail: String?

  /// Stable UI row identity is currently session-agent-scoped. Use `managedAgentID` for daemon
  /// transport calls and `sessionAgentID` when joining back to session state.
  public var id: String { agentId }
  public var managedAgentID: String { acpId }
  public var sessionAgentID: String { agentId }
  public var isRestartable: Bool { disconnectReason?.isRestartable ?? false }

  public init(
    acpId: String,
    sessionId: String,
    agentId: String,
    displayName: String,
    status: AgentStatus,
    pid: UInt32,
    pgid: Int32,
    projectDir: String,
    pendingPermissions: Int,
    permissionQueueDepth: Int,
    pendingPermissionBatches: [AcpPermissionBatch],
    terminalCount: Int,
    createdAt: String,
    updatedAt: String,
    disconnectReason: AgentDisconnectReason? = nil,
    stderrTail: String? = nil
  ) {
    self.acpId = acpId
    self.sessionId = sessionId
    self.agentId = agentId
    self.displayName = displayName
    self.status = status
    self.pid = pid
    self.pgid = pgid
    self.projectDir = projectDir
    self.pendingPermissions = pendingPermissions
    self.permissionQueueDepth = permissionQueueDepth
    self.pendingPermissionBatches = pendingPermissionBatches
    self.terminalCount = terminalCount
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.disconnectReason = disconnectReason
    self.stderrTail = stderrTail
  }

  private enum CodingKeys: String, CodingKey {
    case acpId
    case managedAgentId
    case sessionId
    case agentId
    case sessionAgentId
    case displayName
    case status
    case pid
    case pgid
    case projectDir
    case pendingPermissions
    case permissionQueueDepth
    case pendingPermissionBatches
    case terminalCount
    case createdAt
    case updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    acpId =
      try container.decodeIfPresent(String.self, forKey: .managedAgentId)
      ?? container.decode(String.self, forKey: .acpId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    agentId =
      try container.decodeIfPresent(String.self, forKey: .sessionAgentId)
      ?? container.decode(String.self, forKey: .agentId)
    displayName = try container.decode(String.self, forKey: .displayName)
    status = try container.decode(AgentStatus.self, forKey: .status)
    pid = try container.decode(UInt32.self, forKey: .pid)
    pgid = try container.decode(Int32.self, forKey: .pgid)
    projectDir = try container.decode(String.self, forKey: .projectDir)
    pendingPermissions = try container.decode(Int.self, forKey: .pendingPermissions)
    permissionQueueDepth = try container.decode(Int.self, forKey: .permissionQueueDepth)
    pendingPermissionBatches = try container.decode(
      [AcpPermissionBatch].self,
      forKey: .pendingPermissionBatches
    )
    terminalCount = try container.decode(Int.self, forKey: .terminalCount)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    let details = try? container.decode(AcpAgentStatusDetails.self, forKey: .status)
    disconnectReason = details?.reason
    stderrTail = details?.stderrTail
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(acpId, forKey: .acpId)
    try container.encode(acpId, forKey: .managedAgentId)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(agentId, forKey: .agentId)
    try container.encode(agentId, forKey: .sessionAgentId)
    try container.encode(displayName, forKey: .displayName)
    if status == .disconnected && (disconnectReason != nil || stderrTail != nil) {
      try container.encode(
        AcpAgentStatusDetails(
          state: status.rawValue,
          reason: disconnectReason,
          stderrTail: stderrTail
        ),
        forKey: .status
      )
    } else {
      try container.encode(status, forKey: .status)
    }
    try container.encode(pid, forKey: .pid)
    try container.encode(pgid, forKey: .pgid)
    try container.encode(projectDir, forKey: .projectDir)
    try container.encode(pendingPermissions, forKey: .pendingPermissions)
    try container.encode(permissionQueueDepth, forKey: .permissionQueueDepth)
    try container.encode(pendingPermissionBatches, forKey: .pendingPermissionBatches)
    try container.encode(terminalCount, forKey: .terminalCount)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

private struct AcpAgentStatusDetails: Codable, Equatable, Sendable {
  let state: String
  let reason: AgentDisconnectReason?
  let stderrTail: String?
}

extension AcpPermissionItem {
  public var requestIdentity: AcpPermissionRequestID {
    AcpPermissionRequestID(rawValue: requestId)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }
}

extension AcpPermissionBatch {
  public var batchIdentity: AcpPermissionBatchID {
    AcpPermissionBatchID(rawValue: batchId)
  }

  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: acpId)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }
}

extension AcpAgentSnapshot {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }

  public var sessionAgentIdentity: SessionAgentID {
    SessionAgentID(rawValue: sessionAgentID)
  }
}
