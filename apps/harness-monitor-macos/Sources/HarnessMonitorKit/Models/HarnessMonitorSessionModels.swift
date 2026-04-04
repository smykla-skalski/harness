import Foundation

public struct WorktreeSummary: Codable, Equatable, Identifiable, Sendable {
  public let checkoutId: String
  public let name: String
  public let checkoutRoot: String
  public let contextRoot: String
  public let activeSessionCount: Int
  public let totalSessionCount: Int

  public var id: String { checkoutId }

  public init(
    checkoutId: String,
    name: String,
    checkoutRoot: String,
    contextRoot: String,
    activeSessionCount: Int,
    totalSessionCount: Int
  ) {
    self.checkoutId = checkoutId
    self.name = name
    self.checkoutRoot = checkoutRoot
    self.contextRoot = contextRoot
    self.activeSessionCount = activeSessionCount
    self.totalSessionCount = totalSessionCount
  }
}

public struct ProjectSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let name: String
  public let projectDir: String?
  public let contextRoot: String
  public let activeSessionCount: Int
  public let totalSessionCount: Int
  public let worktrees: [WorktreeSummary]

  public var id: String { projectId }

  public init(
    projectId: String,
    name: String,
    projectDir: String?,
    contextRoot: String,
    activeSessionCount: Int,
    totalSessionCount: Int,
    worktrees: [WorktreeSummary] = []
  ) {
    self.projectId = projectId
    self.name = name
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.activeSessionCount = activeSessionCount
    self.totalSessionCount = totalSessionCount
    self.worktrees = worktrees
  }

  enum CodingKeys: String, CodingKey {
    case projectId, name, projectDir, contextRoot, activeSessionCount, totalSessionCount, worktrees
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      projectId: try container.decode(String.self, forKey: .projectId),
      name: try container.decode(String.self, forKey: .name),
      projectDir: try container.decodeIfPresent(String.self, forKey: .projectDir),
      contextRoot: try container.decode(String.self, forKey: .contextRoot),
      activeSessionCount: try container.decode(Int.self, forKey: .activeSessionCount),
      totalSessionCount: try container.decode(Int.self, forKey: .totalSessionCount),
      worktrees: try container.decodeIfPresent([WorktreeSummary].self, forKey: .worktrees) ?? []
    )
  }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case active
  case paused
  case ended

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .paused:
      "Paused"
    case .ended:
      "Ended"
    }
  }
}

public struct SessionMetrics: Codable, Equatable, Sendable {
  public let agentCount: Int
  public let activeAgentCount: Int
  public let openTaskCount: Int
  public let inProgressTaskCount: Int
  public let blockedTaskCount: Int
  public let completedTaskCount: Int
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let projectName: String
  public let projectDir: String?
  public let contextRoot: String
  public let checkoutId: String
  public let checkoutRoot: String
  public let isWorktree: Bool
  public let worktreeName: String?
  public let sessionId: String
  public let title: String
  public let context: String
  public let status: SessionStatus
  public let createdAt: String
  public let updatedAt: String
  public let lastActivityAt: String?
  public let leaderId: String?
  public let observeId: String?
  public let pendingLeaderTransfer: PendingLeaderTransfer?
  public let metrics: SessionMetrics

  public var id: String { sessionId }

  public var displayTitle: String { title.isEmpty ? "(untitled)" : title }

  public init(
    projectId: String,
    projectName: String,
    projectDir: String?,
    contextRoot: String,
    checkoutId: String? = nil,
    checkoutRoot: String? = nil,
    isWorktree: Bool = false,
    worktreeName: String? = nil,
    sessionId: String,
    title: String = "",
    context: String,
    status: SessionStatus,
    createdAt: String,
    updatedAt: String,
    lastActivityAt: String?,
    leaderId: String?,
    observeId: String?,
    pendingLeaderTransfer: PendingLeaderTransfer?,
    metrics: SessionMetrics
  ) {
    self.projectId = projectId
    self.projectName = projectName
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.checkoutId = checkoutId ?? projectId
    self.checkoutRoot = checkoutRoot ?? projectDir ?? contextRoot
    self.isWorktree = isWorktree
    self.worktreeName = worktreeName
    self.sessionId = sessionId
    self.title = title
    self.context = context
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastActivityAt = lastActivityAt
    self.leaderId = leaderId
    self.observeId = observeId
    self.pendingLeaderTransfer = pendingLeaderTransfer
    self.metrics = metrics
  }

  public var checkoutDisplayName: String {
    if isWorktree {
      return worktreeName ?? URL(fileURLWithPath: checkoutRoot).lastPathComponent
    }
    return "Repository"
  }

  enum CodingKeys: String, CodingKey {
    case projectId, projectName, projectDir, contextRoot
    case checkoutId, checkoutRoot, isWorktree, worktreeName
    case sessionId, title, context, status, createdAt, updatedAt, lastActivityAt
    case leaderId, observeId, pendingLeaderTransfer, metrics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let projectId = try container.decode(String.self, forKey: .projectId)
    let projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
    let contextRoot = try container.decode(String.self, forKey: .contextRoot)
    self.init(
      projectId: projectId,
      projectName: try container.decode(String.self, forKey: .projectName),
      projectDir: projectDir,
      contextRoot: contextRoot,
      checkoutId: try container.decodeIfPresent(String.self, forKey: .checkoutId) ?? projectId,
      checkoutRoot: try container.decodeIfPresent(String.self, forKey: .checkoutRoot)
        ?? projectDir ?? contextRoot,
      isWorktree: try container.decodeIfPresent(Bool.self, forKey: .isWorktree) ?? false,
      worktreeName: try container.decodeIfPresent(String.self, forKey: .worktreeName),
      sessionId: try container.decode(String.self, forKey: .sessionId),
      title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
      context: try container.decode(String.self, forKey: .context),
      status: try container.decode(SessionStatus.self, forKey: .status),
      createdAt: try container.decode(String.self, forKey: .createdAt),
      updatedAt: try container.decode(String.self, forKey: .updatedAt),
      lastActivityAt: try container.decodeIfPresent(String.self, forKey: .lastActivityAt),
      leaderId: try container.decodeIfPresent(String.self, forKey: .leaderId),
      observeId: try container.decodeIfPresent(String.self, forKey: .observeId),
      pendingLeaderTransfer: try container.decodeIfPresent(
        PendingLeaderTransfer.self,
        forKey: .pendingLeaderTransfer
      ),
      metrics: try container.decode(SessionMetrics.self, forKey: .metrics)
    )
  }
}

public struct PendingLeaderTransfer: Codable, Equatable, Sendable {
  public let requestedBy: String
  public let currentLeaderId: String
  public let newLeaderId: String
  public let requestedAt: String
  public let reason: String?
}

public struct HookIntegrationDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let typicalLatencySeconds: Int
  public let supportsContextInjection: Bool

  public var id: String { name }
}

public struct RuntimeCapabilities: Codable, Equatable, Sendable {
  public let runtime: String
  public let supportsNativeTranscript: Bool
  public let supportsSignalDelivery: Bool
  public let supportsContextInjection: Bool
  public let typicalSignalLatencySeconds: Int
  public let hookPoints: [HookIntegrationDescriptor]
}

public enum SessionRole: String, Codable, CaseIterable, Sendable {
  case leader
  case observer
  case worker
  case reviewer
  case improver

  public var title: String {
    switch self {
    case .leader:
      "Leader"
    case .observer:
      "Observer"
    case .worker:
      "Worker"
    case .reviewer:
      "Reviewer"
    case .improver:
      "Improver"
    }
  }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
  case active
  case disconnected
  case removed

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .disconnected:
      "Disconnected"
    case .removed:
      "Removed"
    }
  }
}

public struct AgentRegistration: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let name: String
  public let runtime: String
  public let role: SessionRole
  public let capabilities: [String]
  public let joinedAt: String
  public let updatedAt: String
  public let status: AgentStatus
  public let agentSessionId: String?
  public let lastActivityAt: String?
  public let currentTaskId: String?
  public let runtimeCapabilities: RuntimeCapabilities

  public var id: String { agentId }
}

public enum TaskSeverity: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case critical

  public var title: String {
    switch self {
    case .low:
      "Low"
    case .medium:
      "Medium"
    case .high:
      "High"
    case .critical:
      "Critical"
    }
  }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
  case open
  case inProgress
  case inReview
  case done
  case blocked

  public var title: String {
    switch self {
    case .open:
      "Open"
    case .inProgress:
      "In Progress"
    case .inReview:
      "In Review"
    case .done:
      "Done"
    case .blocked:
      "Blocked"
    }
  }
}

public enum TaskSource: String, Codable, CaseIterable, Sendable {
  case manual
  case observe
  case signal
  case system

  public var title: String {
    switch self {
    case .manual:
      "Manual"
    case .observe:
      "Observe"
    case .signal:
      "Signal"
    case .system:
      "System"
    }
  }
}

public struct TaskNote: Codable, Equatable, Identifiable, Sendable {
  public let timestamp: String
  public let agentId: String?
  public let text: String
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case timestamp, agentId, text }

  public init(timestamp: String, agentId: String?, text: String) {
    self.timestamp = timestamp
    self.agentId = agentId
    self.text = text
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.timestamp == rhs.timestamp && lhs.agentId == rhs.agentId && lhs.text == rhs.text
  }
}

public struct TaskCheckpointSummary: Codable, Equatable, Sendable {
  public let checkpointId: String
  public let recordedAt: String
  public let actorId: String?
  public let summary: String
  public let progress: Int
}

public struct WorkItem: Codable, Equatable, Identifiable, Sendable {
  public let taskId: String
  public let title: String
  public let context: String?
  public let severity: TaskSeverity
  public let status: TaskStatus
  public let assignedTo: String?
  public let createdAt: String
  public let updatedAt: String
  public let createdBy: String?
  public let notes: [TaskNote]
  public let suggestedFix: String?
  public let source: TaskSource
  public let blockedReason: String?
  public let completedAt: String?
  public let checkpointSummary: TaskCheckpointSummary?

  public var id: String { taskId }

  enum CodingKeys: String, CodingKey {
    case taskId
    case title
    case context
    case severity
    case status
    case assignedTo
    case createdAt
    case updatedAt
    case createdBy
    case notes
    case suggestedFix
    case source
    case blockedReason
    case completedAt
    case checkpointSummary
  }

  public init(
    taskId: String,
    title: String,
    context: String?,
    severity: TaskSeverity,
    status: TaskStatus,
    assignedTo: String?,
    createdAt: String,
    updatedAt: String,
    createdBy: String?,
    notes: [TaskNote],
    suggestedFix: String?,
    source: TaskSource,
    blockedReason: String?,
    completedAt: String?,
    checkpointSummary: TaskCheckpointSummary?
  ) {
    self.taskId = taskId
    self.title = title
    self.context = context
    self.severity = severity
    self.status = status
    self.assignedTo = assignedTo
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.createdBy = createdBy
    self.notes = notes
    self.suggestedFix = suggestedFix
    self.source = source
    self.blockedReason = blockedReason
    self.completedAt = completedAt
    self.checkpointSummary = checkpointSummary
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    taskId = try container.decode(String.self, forKey: .taskId)
    title = try container.decode(String.self, forKey: .title)
    context = try container.decodeIfPresent(String.self, forKey: .context)
    severity = try container.decode(TaskSeverity.self, forKey: .severity)
    status = try container.decode(TaskStatus.self, forKey: .status)
    assignedTo = try container.decodeIfPresent(String.self, forKey: .assignedTo)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
    notes = try container.decodeIfPresent([TaskNote].self, forKey: .notes) ?? []
    suggestedFix = try container.decodeIfPresent(String.self, forKey: .suggestedFix)
    source = try container.decodeIfPresent(TaskSource.self, forKey: .source) ?? .manual
    blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason)
    completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    checkpointSummary = try container.decodeIfPresent(
      TaskCheckpointSummary.self,
      forKey: .checkpointSummary
    )
  }
}

public struct ObserverIssueSummary: Codable, Equatable, Identifiable, Sendable {
  public let issueId: String
  public let code: String
  public let summary: String
  public let severity: String
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

public struct AgentToolActivitySummary: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let runtime: String
  public let toolInvocationCount: Int
  public let toolResultCount: Int
  public let toolErrorCount: Int
  public let latestToolName: String?
  public let latestEventAt: String?
  public let recentTools: [String]

  public var id: String { agentId }
}

public struct SessionDetail: Codable, Equatable, Sendable {
  public let session: SessionSummary
  public let agents: [AgentRegistration]
  public let tasks: [WorkItem]
  public let signals: [SessionSignalRecord]
  public let observer: ObserverSummary?
  public let agentActivity: [AgentToolActivitySummary]
}
