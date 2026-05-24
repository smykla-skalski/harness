import Foundation

public struct TaskBoardEvaluateRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?
  public let itemId: String?
  public let dryRun: Bool

  public init(
    status: TaskBoardStatus? = nil,
    itemId: String? = nil,
    dryRun: Bool = false
  ) {
    self.status = status
    self.itemId = itemId
    self.dryRun = dryRun
  }
}

public enum TaskBoardEvaluationOutcome: String, Codable, Sendable {
  case skippedUnlinked = "skipped_unlinked"
  case missingSession = "missing_session"
  case missingTask = "missing_task"
  case workerPending = "worker_pending"
  case workerRunning = "worker_running"
  case reviewPending = "review_pending"
  case reviewRunning = "review_running"
  case reviewChangesRequested = "review_changes_requested"
  case completed
  case blocked
}

public struct TaskBoardEvaluationRecord: Codable, Equatable, Identifiable, Sendable {
  public let boardItemId: String
  public let sessionId: String?
  public let workItemId: String?
  public let outcome: TaskBoardEvaluationOutcome
  public let taskStatus: TaskStatus?
  public let boardStatus: TaskBoardStatus?
  public let workflowStatus: TaskBoardWorkflowStatus?
  public let updated: Bool
  public let reason: String?
  public let item: TaskBoardItem?

  public var id: String { boardItemId }

  public init(
    boardItemId: String,
    sessionId: String? = nil,
    workItemId: String? = nil,
    outcome: TaskBoardEvaluationOutcome,
    taskStatus: TaskStatus? = nil,
    boardStatus: TaskBoardStatus? = nil,
    workflowStatus: TaskBoardWorkflowStatus? = nil,
    updated: Bool = false,
    reason: String? = nil,
    item: TaskBoardItem? = nil
  ) {
    self.boardItemId = boardItemId
    self.sessionId = sessionId
    self.workItemId = workItemId
    self.outcome = outcome
    self.taskStatus = taskStatus
    self.boardStatus = boardStatus
    self.workflowStatus = workflowStatus
    self.updated = updated
    self.reason = reason
    self.item = item
  }
}

public struct TaskBoardEvaluationSummary: Codable, Equatable, Sendable {
  public let total: Int
  public let evaluated: Int
  public let updated: Int
  public let skipped: Int
  public let completed: Int
  public let running: Int
  public let reviewing: Int
  public let blocked: Int
  public let failed: Int
  public let records: [TaskBoardEvaluationRecord]

  public init(
    total: Int = 0,
    evaluated: Int = 0,
    updated: Int = 0,
    skipped: Int = 0,
    completed: Int = 0,
    running: Int = 0,
    reviewing: Int = 0,
    blocked: Int = 0,
    failed: Int = 0,
    records: [TaskBoardEvaluationRecord] = []
  ) {
    self.total = total
    self.evaluated = evaluated
    self.updated = updated
    self.skipped = skipped
    self.completed = completed
    self.running = running
    self.reviewing = reviewing
    self.blocked = blocked
    self.failed = failed
    self.records = records
  }
}
