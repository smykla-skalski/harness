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

public enum TaskDropTarget: Codable, Equatable, Sendable {
  case agent(agentId: String)

  enum CodingKeys: String, CodingKey {
    case targetType
    case agentId
  }

  enum TargetType: String, Codable {
    case agent
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let targetType = try container.decode(TargetType.self, forKey: .targetType)
    switch targetType {
    case .agent:
      self = .agent(agentId: try container.decode(String.self, forKey: .agentId))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .agent(let agentId):
      try container.encode(TargetType.agent, forKey: .targetType)
      try container.encode(agentId, forKey: .agentId)
    }
  }
}

public struct TaskDropRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let target: TaskDropTarget
  public let queuePolicy: TaskQueuePolicy

  public init(
    actor: String,
    target: TaskDropTarget,
    queuePolicy: TaskQueuePolicy = .locked
  ) {
    self.actor = actor
    self.target = target
    self.queuePolicy = queuePolicy
  }
}

public struct TaskQueuePolicyRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let queuePolicy: TaskQueuePolicy

  public init(actor: String, queuePolicy: TaskQueuePolicy) {
    self.actor = actor
    self.queuePolicy = queuePolicy
  }
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

public struct TaskSubmitForReviewRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let summary: String?
  public let suggestedPersona: String?

  public init(
    actor: String,
    summary: String? = nil,
    suggestedPersona: String? = nil
  ) {
    self.actor = actor
    self.summary = summary
    self.suggestedPersona = suggestedPersona
  }
}

public struct TaskClaimReviewRequest: Codable, Equatable, Sendable {
  public let actor: String

  public init(actor: String) {
    self.actor = actor
  }
}

public struct TaskSubmitReviewRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let verdict: ReviewVerdict
  public let summary: String
  public let points: [ReviewPoint]

  public init(
    actor: String,
    verdict: ReviewVerdict,
    summary: String,
    points: [ReviewPoint] = []
  ) {
    self.actor = actor
    self.verdict = verdict
    self.summary = summary
    self.points = points
  }
}

public struct TaskRespondReviewRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let agreed: [String]
  public let disputed: [String]
  public let note: String?

  public init(
    actor: String,
    agreed: [String] = [],
    disputed: [String] = [],
    note: String? = nil
  ) {
    self.actor = actor
    self.agreed = agreed
    self.disputed = disputed
    self.note = note
  }
}

public struct TaskArbitrateRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let verdict: ReviewVerdict
  public let summary: String

  public init(actor: String, verdict: ReviewVerdict, summary: String) {
    self.actor = actor
    self.verdict = verdict
    self.summary = summary
  }
}

public struct ImproverApplyRequest: Codable, Equatable, Sendable {
  public let actor: String
  public let issueId: String
  public let target: ImproverTarget
  public let relPath: String
  public let newContents: String
  public let projectDir: String
  public let dryRun: Bool

  public init(
    actor: String,
    issueId: String,
    target: ImproverTarget,
    relPath: String,
    newContents: String,
    projectDir: String,
    dryRun: Bool = false
  ) {
    self.actor = actor
    self.issueId = issueId
    self.target = target
    self.relPath = relPath
    self.newContents = newContents
    self.projectDir = projectDir
    self.dryRun = dryRun
  }
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

public struct HostBridgeReconfigureRequest: Codable, Equatable, Sendable {
  public let enable: [String]
  public let disable: [String]
  public let force: Bool

  public init(
    enable: [String] = [],
    disable: [String] = [],
    force: Bool = false
  ) {
    self.enable = enable
    self.disable = disable
    self.force = force
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
