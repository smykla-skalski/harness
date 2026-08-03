public struct CodexAgentInspectSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let agentId: String?
  public let displayName: String
  public let status: CodexRunStatus
  public let projectDir: String
  public let threadId: String?
  public let turnId: String?
  public let active: Bool
  public let attached: Bool
  public let pendingApprovals: Int
  public let resolvedApprovals: Int
  public let eventCount: Int
  public let lastUpdateAt: String
  public let model: String?
  public let effort: String?
  public let latestSummary: String?
  public let error: String?

  public var id: String { runId }

  public init(
    runId: String,
    sessionId: String,
    agentId: String?,
    displayName: String,
    status: CodexRunStatus,
    projectDir: String,
    threadId: String?,
    turnId: String?,
    active: Bool,
    attached: Bool,
    pendingApprovals: Int,
    resolvedApprovals: Int,
    eventCount: Int,
    lastUpdateAt: String,
    model: String?,
    effort: String?,
    latestSummary: String?,
    error: String?
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.agentId = agentId
    self.displayName = displayName
    self.status = status
    self.projectDir = projectDir
    self.threadId = threadId
    self.turnId = turnId
    self.active = active
    self.attached = attached
    self.pendingApprovals = pendingApprovals
    self.resolvedApprovals = resolvedApprovals
    self.eventCount = eventCount
    self.lastUpdateAt = lastUpdateAt
    self.model = model
    self.effort = effort
    self.latestSummary = latestSummary
    self.error = error
  }
}

public struct CodexApprovalRequest: Codable, Equatable, Identifiable, Sendable {
  public let approvalId: String
  public let requestId: String
  public let kind: String
  public let title: String
  public let detail: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let cwd: String?
  public let command: String?
  public let filePath: String?

  public var id: String { approvalId }

  public init(
    approvalId: String,
    requestId: String,
    kind: String,
    title: String,
    detail: String,
    threadId: String?,
    turnId: String?,
    itemId: String?,
    cwd: String?,
    command: String?,
    filePath: String?
  ) {
    self.approvalId = approvalId
    self.requestId = requestId
    self.kind = kind
    self.title = title
    self.detail = detail
    self.threadId = threadId
    self.turnId = turnId
    self.itemId = itemId
    self.cwd = cwd
    self.command = command
    self.filePath = filePath
  }
}

public struct CodexRunEvent: Codable, Equatable, Identifiable, Sendable {
  public let eventId: String
  public let sequence: UInt64
  public let recordedAt: String
  public let kind: String
  public let summary: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let payload: JSONValue

  public var id: String { eventId }

  public init(
    eventId: String,
    sequence: UInt64,
    recordedAt: String,
    kind: String,
    summary: String,
    threadId: String?,
    turnId: String?,
    itemId: String?,
    payload: JSONValue
  ) {
    self.eventId = eventId
    self.sequence = sequence
    self.recordedAt = recordedAt
    self.kind = kind
    self.summary = summary
    self.threadId = threadId
    self.turnId = turnId
    self.itemId = itemId
    self.payload = payload
  }
}
