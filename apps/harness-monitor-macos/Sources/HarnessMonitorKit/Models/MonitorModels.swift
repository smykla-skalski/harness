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

  public var id: String { "\(timestamp)-\(text)" }
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

public enum SignalPriority: String, Codable, CaseIterable, Sendable {
  case low
  case normal
  case high
  case urgent
}

public struct DeliveryConfig: Codable, Equatable, Sendable {
  public let maxRetries: Int
  public let retryCount: Int
  public let idempotencyKey: String?
}

public enum JSONValue: Codable, Equatable, Sendable {
  case array([Self])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: Self])
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([String: Self].self) {
      self = .object(value)
    } else if let value = try? container.decode([Self].self) {
      self = .array(value)
    } else if container.decodeNil() {
      self = .null
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON payload",
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}

public struct SignalPayload: Codable, Equatable, Sendable {
  public let message: String
  public let actionHint: String?
  public let relatedFiles: [String]
  public let metadata: JSONValue
}

public struct Signal: Codable, Equatable, Identifiable, Sendable {
  public let signalId: String
  public let version: Int
  public let createdAt: String
  public let expiresAt: String
  public let sourceAgent: String
  public let command: String
  public let priority: SignalPriority
  public let payload: SignalPayload
  public let delivery: DeliveryConfig

  public var id: String { signalId }
}

public enum AckResult: String, Codable, CaseIterable, Sendable {
  case accepted
  case rejected
  case deferred
  case expired
}

public struct SignalAck: Codable, Equatable, Identifiable, Sendable {
  public let signalId: String
  public let acknowledgedAt: String
  public let result: AckResult
  public let agent: String
  public let sessionId: String
  public let details: String?

  public var id: String { signalId }
}

public enum SessionSignalStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case acknowledged
  case rejected
  case deferred
  case expired
}

public struct SessionSignalRecord: Codable, Equatable, Identifiable, Sendable {
  public let runtime: String
  public let agentId: String
  public let sessionId: String
  public let status: SessionSignalStatus
  public let signal: Signal
  public let acknowledgment: SignalAck?

  public var id: String { signal.signalId }
}

public struct ObserverSummary: Codable, Equatable, Sendable {
  public let observeId: String
  public let lastScanTime: String
  public let openIssueCount: Int
  public let mutedCodeCount: Int
  public let activeWorkerCount: Int
}

public struct SessionDetail: Codable, Equatable, Sendable {
  public let session: SessionSummary
  public let agents: [AgentRegistration]
  public let tasks: [WorkItem]
  public let signals: [SessionSignalRecord]
  public let observer: ObserverSummary?
}

public struct TimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public let entryId: String
  public let recordedAt: String
  public let kind: String
  public let sessionId: String
  public let agentId: String?
  public let taskId: String?
  public let summary: String
  public let payload: JSONValue

  public var id: String { entryId }
}

public struct StreamEvent: Codable, Equatable, Identifiable, Sendable {
  public let event: String
  public let recordedAt: String
  public let sessionId: String?
  public let payload: JSONValue

  public var id: String { "\(event)-\(recordedAt)-\(sessionId ?? "global")" }
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
