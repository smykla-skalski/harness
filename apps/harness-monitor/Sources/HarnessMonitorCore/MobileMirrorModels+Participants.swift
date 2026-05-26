import Foundation

public struct MobileStationSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var displayName: String
  public var state: MobileStationState
  public var lastSeenAt: Date
  public var activeSessionCount: Int
  public var needsYouCount: Int
  public var commandQueueCount: Int
  public var defaultStation: Bool

  public init(
    id: String,
    displayName: String,
    state: MobileStationState,
    lastSeenAt: Date,
    activeSessionCount: Int,
    needsYouCount: Int,
    commandQueueCount: Int,
    defaultStation: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.state = state
    self.lastSeenAt = lastSeenAt
    self.activeSessionCount = activeSessionCount
    self.needsYouCount = needsYouCount
    self.commandQueueCount = commandQueueCount
    self.defaultStation = defaultStation
  }
}

public struct MobileAttentionItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var kind: MobileAttentionKind
  public var severity: MobileAttentionSeverity
  public var title: String
  public var subtitle: String
  public var updatedAt: Date
  public var commandKind: MobileCommandKind?
  public var target: MobileCommandTarget?
  public var commandPayload: [String: String]

  public init(
    id: String,
    stationID: String,
    kind: MobileAttentionKind,
    severity: MobileAttentionSeverity,
    title: String,
    subtitle: String,
    updatedAt: Date,
    commandKind: MobileCommandKind? = nil,
    target: MobileCommandTarget? = nil,
    commandPayload: [String: String] = [:]
  ) {
    self.id = id
    self.stationID = stationID
    self.kind = kind
    self.severity = severity
    self.title = title
    self.subtitle = subtitle
    self.updatedAt = updatedAt
    self.commandKind = commandKind
    self.target = target
    self.commandPayload = commandPayload
  }

  public var needsUserAction: Bool {
    severity != .info
  }

  public var confirmationMessage: String {
    subtitle.isEmpty ? title : "\(title)\n\(subtitle)"
  }
}

public struct MobileSessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var projectName: String
  public var title: String
  public var branch: String
  public var status: String
  public var activeAgentCount: Int
  public var blockedAgentCount: Int
  public var lastActivityAt: Date
  public var summary: String
  public var agents: [MobileAgentSummary]

  public init(
    id: String,
    stationID: String,
    projectName: String,
    title: String,
    branch: String,
    status: String,
    activeAgentCount: Int,
    blockedAgentCount: Int,
    lastActivityAt: Date,
    summary: String,
    agents: [MobileAgentSummary] = []
  ) {
    self.id = id
    self.stationID = stationID
    self.projectName = projectName
    self.title = title
    self.branch = branch
    self.status = status
    self.activeAgentCount = activeAgentCount
    self.blockedAgentCount = blockedAgentCount
    self.lastActivityAt = lastActivityAt
    self.summary = summary
    self.agents = agents
  }

  enum CodingKeys: String, CodingKey {
    case id
    case stationID
    case projectName
    case title
    case branch
    case status
    case activeAgentCount
    case blockedAgentCount
    case lastActivityAt
    case summary
    case agents
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      stationID: try container.decode(String.self, forKey: .stationID),
      projectName: try container.decode(String.self, forKey: .projectName),
      title: try container.decode(String.self, forKey: .title),
      branch: try container.decode(String.self, forKey: .branch),
      status: try container.decode(String.self, forKey: .status),
      activeAgentCount: try container.decode(Int.self, forKey: .activeAgentCount),
      blockedAgentCount: try container.decode(Int.self, forKey: .blockedAgentCount),
      lastActivityAt: try container.decode(Date.self, forKey: .lastActivityAt),
      summary: try container.decode(String.self, forKey: .summary),
      agents: try container.decodeIfPresent([MobileAgentSummary].self, forKey: .agents) ?? []
    )
  }
}

public enum MobileAgentFamily: String, Codable, CaseIterable, Sendable {
  case terminal
  case codex
  case acp

  public var title: String {
    switch self {
    case .terminal: "Terminal"
    case .codex: "Codex"
    case .acp: "ACP"
    }
  }
}

public struct MobileAgentSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var sessionID: String
  public var displayName: String
  public var family: MobileAgentFamily
  public var status: String
  public var role: String?
  public var isActive: Bool
  public var isBlocked: Bool
  public var pendingApprovalCount: Int
  public var pendingPermissionCount: Int
  public var lastActivityAt: Date
  public var summary: String

  public init(
    id: String,
    stationID: String,
    sessionID: String,
    displayName: String,
    family: MobileAgentFamily,
    status: String,
    role: String? = nil,
    isActive: Bool,
    isBlocked: Bool,
    pendingApprovalCount: Int = 0,
    pendingPermissionCount: Int = 0,
    lastActivityAt: Date,
    summary: String = ""
  ) {
    self.id = id
    self.stationID = stationID
    self.sessionID = sessionID
    self.displayName = displayName
    self.family = family
    self.status = status
    self.role = role
    self.isActive = isActive
    self.isBlocked = isBlocked
    self.pendingApprovalCount = pendingApprovalCount
    self.pendingPermissionCount = pendingPermissionCount
    self.lastActivityAt = lastActivityAt
    self.summary = summary
  }

  public func promptDraft(
    prompt: String,
    targetRevision: Int64,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    MobileCommandDraft(
      kind: .agentPrompt,
      confirmationText: "Send prompt to \(displayName).",
      target: commandTarget(targetRevision: targetRevision),
      payload: ["prompt": prompt],
      expiresAfter: expiresAfter
    )
  }

  public func stopDraft(
    targetRevision: Int64,
    expiresAfter: TimeInterval = 15 * 60
  ) -> MobileCommandDraft {
    MobileCommandDraft(
      kind: .agentStop,
      confirmationText: "Stop \(displayName).",
      target: commandTarget(targetRevision: targetRevision),
      expiresAfter: expiresAfter
    )
  }

  private func commandTarget(targetRevision: Int64) -> MobileCommandTarget {
    MobileCommandTarget(
      stationID: stationID,
      sessionID: sessionID,
      agentID: id,
      targetRevision: targetRevision
    )
  }
}
