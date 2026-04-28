import Foundation

public struct AcpPermissionItem: Codable, Equatable, Sendable {
  public let requestId: String
  public let sessionId: String
  public let toolCall: JSONValue
  public let options: [JSONValue]
}

public struct AcpPermissionBatch: Codable, Equatable, Sendable {
  public let batchId: String
  public let acpId: String
  public let sessionId: String
  public let requests: [AcpPermissionItem]
  public let createdAt: String
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

  public var id: String { acpId }
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
    case sessionId
    case agentId
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
    acpId = try container.decode(String.self, forKey: .acpId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    agentId = try container.decode(String.self, forKey: .agentId)
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
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(agentId, forKey: .agentId)
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
