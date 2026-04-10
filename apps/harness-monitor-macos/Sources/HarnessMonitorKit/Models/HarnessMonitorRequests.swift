import Foundation

public struct RoleChangeRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let role: SessionRole
  public let reason: String?

  public init(actor: String, role: SessionRole, reason: String? = nil) {
    self.actor = actor
    self.role = role
    self.reason = reason
  }
}

public struct AgentRemoveRequest: Codable, Equatable, Sendable {
  public let actor: String
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
  public let suggestedFix: String?

  public init(
    actor: String,
    title: String,
    context: String?,
    severity: TaskSeverity,
    suggestedFix: String? = nil
  ) {
    self.actor = actor
    self.title = title
    self.context = context
    self.severity = severity
    self.suggestedFix = suggestedFix
  }
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

public struct SignalCancelRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let agentId: String
  public let signalId: String

  public init(actor: String, agentId: String, signalId: String) {
    self.actor = actor
    self.agentId = agentId
    self.signalId = signalId
  }
}

public struct ErrorEnvelope: Codable, Equatable, Sendable {
  public struct ErrorDetail: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String]
  }

  public let error: ErrorDetail
}
