import Foundation

public struct ProjectSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let name: String
  public let projectDir: String?
  public let contextRoot: String
  public let activeSessionCount: Int
  public let totalSessionCount: Int

  public var id: String { projectId }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case active
  case paused
  case ended
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
  public let sessionId: String
  public let context: String
  public let status: SessionStatus
  public let createdAt: String
  public let updatedAt: String
  public let lastActivityAt: String?
  public let leaderId: String?
  public let observeId: String?
  public let metrics: SessionMetrics

  public var id: String { sessionId }
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
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
  case active
  case disconnected
  case removed
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
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
  case open
  case inProgress
  case inReview
  case done
  case blocked
}

public enum TaskSource: String, Codable, CaseIterable, Sendable {
  case manual
  case observe
  case signal
  case system
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

public struct ObserverSummary: Codable, Equatable, Sendable {
  public let observeId: String
  public let lastScanTime: String
  public let openIssueCount: Int
  public let mutedCodeCount: Int
  public let activeWorkerCount: Int
  public let openIssues: [ObserverIssueSummary]?
  public let mutedCodes: [String]?
  public let activeWorkers: [ObserverWorkerSummary]?
}

public struct SessionDetail: Codable, Equatable, Sendable {
  public let session: SessionSummary
  public let agents: [AgentRegistration]
  public let tasks: [WorkItem]
  public let signals: [SessionSignalRecord]
  public let observer: ObserverSummary?
}

public struct RoleChangeRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let role: SessionRole
}

public struct LeaderTransferRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let newLeaderId: String
  public let reason: String?
}

public struct TaskCreateRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let title: String
  public let context: String?
  public let severity: TaskSeverity
}

public struct TaskAssignRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let agentId: String
}

public struct TaskUpdateRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let status: TaskStatus
  public let note: String?
}

public struct TaskCheckpointRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let summary: String
  public let progress: Int
}

public struct SessionEndRequest: Codable, Equatable, Sendable {
  public let actor: String
}

public struct ObserveSessionRequest: Codable, Equatable, Sendable {
  public let actor: String
}

public struct SignalSendRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let agentId: String
  public let command: String
  public let message: String
  public let actionHint: String?
}

public struct ErrorEnvelope: Codable, Equatable, Sendable {
  public struct ErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String]
  }

  public let error: ErrorDetail
}
