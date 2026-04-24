import Foundation

public struct ObserverIssueSummary: Codable, Equatable, Identifiable, Sendable {
  public let issueId: String
  public let code: String
  public let summary: String
  public let severity: String
  public let category: String
  public let fingerprint: String?
  public let firstSeenLine: Int?
  public let lastSeenLine: Int?
  public let occurrenceCount: Int?
  public let fixSafety: String?
  public let evidenceExcerpt: String?

  public var id: String { issueId }
}

public struct ObserverWorkerSummary: Codable, Equatable, Identifiable, Sendable {
  public let issueId: String
  public let targetFile: String
  public let startedAt: String
  public let agentId: String?
  public let runtime: String?
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case issueId, targetFile, startedAt, agentId, runtime }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.issueId == rhs.issueId && lhs.targetFile == rhs.targetFile
      && lhs.startedAt == rhs.startedAt && lhs.agentId == rhs.agentId
      && lhs.runtime == rhs.runtime
  }
}

public struct ObserverCycleSummary: Codable, Equatable, Identifiable, Sendable {
  public let timestamp: String
  public let fromLine: Int
  public let toLine: Int
  public let newIssues: Int
  public let resolved: Int

  public var id: String { timestamp }
}

public struct ObserverAgentSessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let runtime: String
  public let logPath: String?
  public let cursor: Int
  public let lastActivity: String?

  public var id: String { agentId }
}

public struct ObserverSummary: Codable, Equatable, Sendable {
  public let observeId: String
  public let lastScanTime: String
  public let openIssueCount: Int
  public let resolvedIssueCount: Int
  public let mutedCodeCount: Int
  public let activeWorkerCount: Int
  public let openIssues: [ObserverIssueSummary]?
  public let mutedCodes: [String]?
  public let activeWorkers: [ObserverWorkerSummary]?
  public let cycleHistory: [ObserverCycleSummary]?
  public let agentSessions: [ObserverAgentSessionSummary]?
}

public struct SessionDetail: Codable, Equatable, Sendable {
  public let session: SessionSummary
  public let agents: [AgentRegistration]
  public let tasks: [WorkItem]
  public let signals: [SessionSignalRecord]
  public let observer: ObserverSummary?
  public let agentActivity: [AgentToolActivitySummary]

  public init(
    session: SessionSummary,
    agents: [AgentRegistration],
    tasks: [WorkItem],
    signals: [SessionSignalRecord],
    observer: ObserverSummary?,
    agentActivity: [AgentToolActivitySummary]
  ) {
    self.session = session
    self.agents = agents
    self.tasks = tasks
    self.signals = signals
    self.observer = observer
    self.agentActivity = agentActivity
  }

  enum CodingKeys: String, CodingKey {
    case session, agents, tasks, signals, observer, agentActivity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    session = try container.decode(SessionSummary.self, forKey: .session)
    agents = try container.decode([AgentRegistration].self, forKey: .agents)
    tasks = try container.decode([WorkItem].self, forKey: .tasks)
    signals = try container.decodeIfPresent([SessionSignalRecord].self, forKey: .signals) ?? []
    observer = try container.decodeIfPresent(ObserverSummary.self, forKey: .observer)
    agentActivity =
      try container.decodeIfPresent(
        [AgentToolActivitySummary].self, forKey: .agentActivity
      ) ?? []
  }

  public func merging(extensions: SessionExtensionsPayload) -> Self {
    Self(
      session: session,
      agents: agents,
      tasks: tasks,
      signals: extensions.signals ?? signals,
      observer: extensions.observer ?? observer,
      agentActivity: extensions.agentActivity ?? agentActivity
    )
  }

  public func canonicallySorted() -> Self {
    Self(
      session: session,
      agents: agents.sorted(by: Self.compareAgents),
      tasks: tasks.sorted(by: Self.compareTasks),
      signals: signals,
      observer: observer,
      agentActivity: agentActivity
    )
  }

  private static func compareAgents(_ left: AgentRegistration, _ right: AgentRegistration) -> Bool {
    if left.role.sortPriority != right.role.sortPriority {
      return left.role.sortPriority < right.role.sortPriority
    }
    if left.status.sortPriority != right.status.sortPriority {
      return left.status.sortPriority < right.status.sortPriority
    }
    if left.joinedAt != right.joinedAt {
      return left.joinedAt < right.joinedAt
    }
    return left.agentId < right.agentId
  }

  private static func compareTasks(_ left: WorkItem, _ right: WorkItem) -> Bool {
    if left.severity.sortPriority != right.severity.sortPriority {
      return left.severity.sortPriority > right.severity.sortPriority
    }
    if left.updatedAt != right.updatedAt {
      return left.updatedAt > right.updatedAt
    }
    if left.createdAt != right.createdAt {
      return left.createdAt > right.createdAt
    }
    return left.taskId < right.taskId
  }
}

public struct SessionExtensionsPayload: Codable, Equatable, Sendable {
  public let sessionId: String
  public let signals: [SessionSignalRecord]?
  public let observer: ObserverSummary?
  public let agentActivity: [AgentToolActivitySummary]?
}

extension SessionRole {
  public var sortPriority: Int {
    switch self {
    case .leader:
      0
    case .observer:
      1
    case .reviewer:
      2
    case .improver:
      3
    case .worker:
      4
    }
  }
}

extension AgentStatus {
  public var sortPriority: Int {
    switch self {
    case .active:
      0
    case .awaitingReview:
      1
    case .idle:
      2
    case .disconnected:
      3
    case .removed:
      4
    }
  }
}

extension TaskSeverity {
  public var sortPriority: Int {
    switch self {
    case .low:
      1
    case .medium:
      2
    case .high:
      3
    case .critical:
      4
    }
  }
}
