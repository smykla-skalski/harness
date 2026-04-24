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
  case inProgress = "in_progress"
  case awaitingReview = "awaiting_review"
  case inReview = "in_review"
  case done
  case blocked

  init?(rawOrLegacyValue value: String) {
    switch value {
    case "inProgress":
      self = .inProgress
    case "inReview":
      self = .inReview
    case "awaitingReview":
      self = .awaitingReview
    default:
      self.init(rawValue: value)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let status = Self(rawOrLegacyValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid task status: \(value)"
      )
    }
    self = status
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var title: String {
    switch self {
    case .open:
      "Open"
    case .inProgress:
      "In Progress"
    case .awaitingReview:
      "Awaiting Review"
    case .inReview:
      "In Review"
    case .done:
      "Done"
    case .blocked:
      "Blocked"
    }
  }
}

extension WorkItem {
  public var isPendingDelivery: Bool {
    status == .open && assignedTo != nil && queuedAt == nil
  }

  public var isQueuedForWorker: Bool {
    status == .open && assignedTo != nil && queuedAt != nil
  }

  public var isLeaderAssignable: Bool {
    status == .open && assignedTo == nil
  }

  public var isReassignableQueuedTask: Bool {
    isQueuedForWorker && queuePolicy == .reassignWhenFree
  }

  public var assignmentSummary: String {
    guard let assignedTo else {
      return "Unassigned"
    }
    if isPendingDelivery {
      return "Pending delivery to \(assignedTo)"
    }
    if isQueuedForWorker {
      return "Queued for \(assignedTo)"
    }
    return assignedTo
  }
}

public enum TaskQueuePolicy: String, Codable, CaseIterable, Sendable {
  case locked
  case reassignWhenFree = "reassign_when_free"

  init?(rawOrLegacyValue value: String) {
    switch value {
    case "reassignWhenFree":
      self = .reassignWhenFree
    default:
      self.init(rawValue: value)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let policy = Self(rawOrLegacyValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid task queue policy: \(value)"
      )
    }
    self = policy
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var title: String {
    switch self {
    case .locked:
      "Locked"
    case .reassignWhenFree:
      "Reassign if free"
    }
  }
}

public enum TaskSource: String, Codable, CaseIterable, Sendable {
  case manual
  case observe
  case signal
  case system
  case improver

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
    case .improver:
      "Improver"
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
  public let queuePolicy: TaskQueuePolicy
  public let queuedAt: String?
  public let createdAt: String
  public let updatedAt: String
  public let createdBy: String?
  public let notes: [TaskNote]
  public let suggestedFix: String?
  public let source: TaskSource
  public let blockedReason: String?
  public let completedAt: String?
  public let checkpointSummary: TaskCheckpointSummary?
  public let awaitingReview: AwaitingReview?
  public let reviewClaim: ReviewClaim?
  public let consensus: ReviewConsensus?
  public let reviewRound: Int
  public let arbitration: ArbitrationOutcome?
  public let suggestedPersona: String?

  public var id: String { taskId }

  enum CodingKeys: String, CodingKey {
    case taskId
    case title
    case context
    case severity
    case status
    case assignedTo
    case queuePolicy
    case queuedAt
    case createdAt
    case updatedAt
    case createdBy
    case notes
    case suggestedFix
    case source
    case blockedReason
    case completedAt
    case checkpointSummary
    case awaitingReview
    case reviewClaim
    case consensus
    case reviewRound
    case arbitration
    case suggestedPersona
  }

  public init(
    taskId: String,
    title: String,
    context: String?,
    severity: TaskSeverity,
    status: TaskStatus,
    assignedTo: String?,
    queuePolicy: TaskQueuePolicy = .locked,
    queuedAt: String? = nil,
    createdAt: String,
    updatedAt: String,
    createdBy: String?,
    notes: [TaskNote],
    suggestedFix: String?,
    source: TaskSource,
    blockedReason: String?,
    completedAt: String?,
    checkpointSummary: TaskCheckpointSummary?,
    awaitingReview: AwaitingReview? = nil,
    reviewClaim: ReviewClaim? = nil,
    consensus: ReviewConsensus? = nil,
    reviewRound: Int = 0,
    arbitration: ArbitrationOutcome? = nil,
    suggestedPersona: String? = nil
  ) {
    self.taskId = taskId
    self.title = title
    self.context = context
    self.severity = severity
    self.status = status
    self.assignedTo = assignedTo
    self.queuePolicy = queuePolicy
    self.queuedAt = queuedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.createdBy = createdBy
    self.notes = notes
    self.suggestedFix = suggestedFix
    self.source = source
    self.blockedReason = blockedReason
    self.completedAt = completedAt
    self.checkpointSummary = checkpointSummary
    self.awaitingReview = awaitingReview
    self.reviewClaim = reviewClaim
    self.consensus = consensus
    self.reviewRound = reviewRound
    self.arbitration = arbitration
    self.suggestedPersona = suggestedPersona
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    taskId = try container.decode(String.self, forKey: .taskId)
    title = try container.decode(String.self, forKey: .title)
    context = try container.decodeIfPresent(String.self, forKey: .context)
    severity = try container.decode(TaskSeverity.self, forKey: .severity)
    status = try container.decode(TaskStatus.self, forKey: .status)
    assignedTo = try container.decodeIfPresent(String.self, forKey: .assignedTo)
    queuePolicy =
      try container.decodeIfPresent(TaskQueuePolicy.self, forKey: .queuePolicy) ?? .locked
    queuedAt = try container.decodeIfPresent(String.self, forKey: .queuedAt)
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
    awaitingReview = try container.decodeIfPresent(AwaitingReview.self, forKey: .awaitingReview)
    reviewClaim = try container.decodeIfPresent(ReviewClaim.self, forKey: .reviewClaim)
    consensus = try container.decodeIfPresent(ReviewConsensus.self, forKey: .consensus)
    reviewRound = try container.decodeIfPresent(Int.self, forKey: .reviewRound) ?? 0
    arbitration = try container.decodeIfPresent(ArbitrationOutcome.self, forKey: .arbitration)
    suggestedPersona = try container.decodeIfPresent(String.self, forKey: .suggestedPersona)
  }
}
