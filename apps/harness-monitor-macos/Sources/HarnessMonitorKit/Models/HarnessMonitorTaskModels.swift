import Foundation

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
