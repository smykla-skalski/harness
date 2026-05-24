import Foundation

public enum MobileStationState: String, Codable, CaseIterable, Sendable {
  case online
  case stale
  case offline

  public var title: String {
    switch self {
    case .online: "Online"
    case .stale: "Stale"
    case .offline: "Offline"
    }
  }
}

public enum MobileAttentionSeverity: String, Codable, CaseIterable, Sendable {
  case info
  case warning
  case critical

  public var rank: Int {
    switch self {
    case .critical: 0
    case .warning: 1
    case .info: 2
    }
  }

  public var title: String {
    switch self {
    case .info: "Info"
    case .warning: "Warning"
    case .critical: "Critical"
    }
  }
}

public enum MobileAttentionKind: String, Codable, CaseIterable, Sendable {
  case acpDecision
  case pullRequest
  case blockedAgent
  case commandFailure
  case stationHealth

  public var title: String {
    switch self {
    case .acpDecision: "ACP Decision"
    case .pullRequest: "Pull Request"
    case .blockedAgent: "Blocked Agent"
    case .commandFailure: "Command Failure"
    case .stationHealth: "Station Health"
    }
  }
}

public enum MobileCommandKind: String, Codable, CaseIterable, Sendable {
  case acpPermissionDecision
  case taskBoardDispatch
  case taskBoardPlanApproval
  case agentStart
  case agentStop
  case agentPrompt
  case pullRequestApprove
  case pullRequestLabel
  case pullRequestRerunChecks
  case pullRequestMerge
  case refresh

  public var title: String {
    switch self {
    case .acpPermissionDecision: "Resolve Permission"
    case .taskBoardDispatch: "Dispatch Task"
    case .taskBoardPlanApproval: "Approve Plan"
    case .agentStart: "Start Agent"
    case .agentStop: "Stop Agent"
    case .agentPrompt: "Prompt Agent"
    case .pullRequestApprove: "Approve PR"
    case .pullRequestLabel: "Label PR"
    case .pullRequestRerunChecks: "Rerun Checks"
    case .pullRequestMerge: "Merge PR"
    case .refresh: "Refresh"
    }
  }
}

public enum MobileCommandRisk: String, Codable, CaseIterable, Sendable {
  case low
  case high
  case destructive

  public var requiresFreshState: Bool {
    self != .low
  }
}

public enum MobileCommandStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case queued
  case accepted
  case running
  case succeeded
  case failed
  case expired
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .expired, .cancelled:
      true
    case .draft, .queued, .accepted, .running:
      false
    }
  }

  public var title: String {
    switch self {
    case .draft: "Draft"
    case .queued: "Queued"
    case .accepted: "Accepted"
    case .running: "Running"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .expired: "Expired"
    case .cancelled: "Cancelled"
    }
  }
}

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

  public init(
    id: String,
    stationID: String,
    kind: MobileAttentionKind,
    severity: MobileAttentionSeverity,
    title: String,
    subtitle: String,
    updatedAt: Date,
    commandKind: MobileCommandKind? = nil,
    target: MobileCommandTarget? = nil
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
    summary: String
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
  }
}

public struct MobileReviewSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var stationID: String
  public var repository: String
  public var number: Int
  public var title: String
  public var author: String
  public var state: String
  public var checksSummary: String
  public var needsYou: Bool
  public var updatedAt: Date

  public init(
    id: String,
    stationID: String,
    repository: String,
    number: Int,
    title: String,
    author: String,
    state: String,
    checksSummary: String,
    needsYou: Bool,
    updatedAt: Date
  ) {
    self.id = id
    self.stationID = stationID
    self.repository = repository
    self.number = number
    self.title = title
    self.author = author
    self.state = state
    self.checksSummary = checksSummary
    self.needsYou = needsYou
    self.updatedAt = updatedAt
  }
}

public struct MobileMirrorSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var revision: Int64
  public var generatedAt: Date
  public var expiresAt: Date
  public var stations: [MobileStationSummary]
  public var attention: [MobileAttentionItem]
  public var sessions: [MobileSessionSummary]
  public var reviews: [MobileReviewSummary]
  public var commands: [MobileCommandRecord]
  public var trustedDevices: [MobileDeviceDescriptor]

  public init(
    schemaVersion: Int = 1,
    revision: Int64,
    generatedAt: Date,
    expiresAt: Date,
    stations: [MobileStationSummary],
    attention: [MobileAttentionItem],
    sessions: [MobileSessionSummary],
    reviews: [MobileReviewSummary],
    commands: [MobileCommandRecord],
    trustedDevices: [MobileDeviceDescriptor] = []
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.generatedAt = generatedAt
    self.expiresAt = expiresAt
    self.stations = stations
    self.attention = attention
    self.sessions = sessions
    self.reviews = reviews
    self.commands = commands
    self.trustedDevices = trustedDevices
  }

  public var needsYouCount: Int {
    attention.filter { $0.severity == .critical || $0.kind == .pullRequest }.count
  }

  public var sortedAttention: [MobileAttentionItem] {
    attention.sorted {
      if $0.severity.rank != $1.severity.rank {
        return $0.severity.rank < $1.severity.rank
      }
      return $0.updatedAt > $1.updatedAt
    }
  }
}
