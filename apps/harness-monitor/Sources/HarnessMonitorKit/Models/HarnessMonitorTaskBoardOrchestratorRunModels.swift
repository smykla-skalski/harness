import Foundation

public struct TaskBoardOrchestratorRunOnceRequest: Codable, Equatable, Sendable {
  public let itemId: String?
  public let dryRun: Bool?
  public let status: TaskBoardStatus?
  public let projectDir: String?
  public let actor: String?

  public init(
    itemId: String? = nil,
    dryRun: Bool? = nil,
    status: TaskBoardStatus? = nil,
    projectDir: String? = nil,
    actor: String? = nil
  ) {
    self.itemId = itemId
    self.dryRun = dryRun
    self.status = status
    self.projectDir = projectDir
    self.actor = actor
  }
}

public enum TaskBoardOrchestratorTickPhase: String, Codable, Sendable {
  case starting
  case dispatch
  case evaluation
  case completed
  case failed
}

public enum TaskBoardOrchestratorRunStatus: String, Codable, Sendable {
  case completed
  case failed
}

public struct TaskBoardOrchestratorTickInfo: Codable, Equatable, Sendable {
  public let runId: String
  public let phase: TaskBoardOrchestratorTickPhase
  public let startedAt: String
  public let completedAt: String?
  public let dryRun: Bool

  public init(
    runId: String,
    phase: TaskBoardOrchestratorTickPhase,
    startedAt: String,
    completedAt: String? = nil,
    dryRun: Bool
  ) {
    self.runId = runId
    self.phase = phase
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.dryRun = dryRun
  }
}

/// Thin projection of an applied dispatch inside an orchestrator run: the
/// direct dispatch endpoint's own `TaskBoardDispatchAppliedTask` carries the
/// full `TaskBoardItem`, but the orchestrator status embedding only ever
/// needs the title for display, so the wire contract stops short of the
/// domain entity.
public struct TaskBoardOrchestratorAppliedTask: Codable, Equatable, Identifiable, Sendable {
  public let boardItemId: String
  public let sessionId: String
  public let workItemId: String
  public let itemTitle: String

  public var id: String { boardItemId }

  public init(boardItemId: String, sessionId: String, workItemId: String, itemTitle: String) {
    self.boardItemId = boardItemId
    self.sessionId = sessionId
    self.workItemId = workItemId
    self.itemTitle = itemTitle
  }
}

public struct TaskBoardOrchestratorDispatchOutcome: Codable, Equatable, Sendable {
  public let plans: [TaskBoardDispatchPlan]
  public let applied: [TaskBoardOrchestratorAppliedTask]
  public let failures: [TaskBoardDispatchFailure]

  public init(
    plans: [TaskBoardDispatchPlan] = [],
    applied: [TaskBoardOrchestratorAppliedTask],
    failures: [TaskBoardDispatchFailure] = []
  ) {
    self.plans = plans
    self.applied = applied
    self.failures = failures
  }
}

/// Thin projection of an evaluation record inside an orchestrator run: see
/// `TaskBoardOrchestratorAppliedTask` for why `item` becomes `itemTitle`.
public struct TaskBoardOrchestratorEvaluationRecord: Codable, Equatable, Identifiable, Sendable {
  public let boardItemId: String
  public let sessionId: String?
  public let workItemId: String?
  public let outcome: TaskBoardEvaluationOutcome
  public let taskStatus: TaskStatus?
  public let boardStatus: TaskBoardStatus?
  public let workflowStatus: TaskBoardWorkflowStatus?
  public let updated: Bool
  public let reason: String?
  public let itemTitle: String?

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
    itemTitle: String? = nil
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
    self.itemTitle = itemTitle
  }
}

public struct TaskBoardOrchestratorEvaluationOutcome: Codable, Equatable, Sendable {
  public let total: Int
  public let evaluated: Int
  public let updated: Int
  public let skipped: Int
  public let completed: Int
  public let running: Int
  public let reviewing: Int
  public let blocked: Int
  public let failed: Int
  public let records: [TaskBoardOrchestratorEvaluationRecord]

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
    records: [TaskBoardOrchestratorEvaluationRecord] = []
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

public struct TaskBoardOrchestratorRunSummary: Codable, Equatable, Sendable {
  public let runId: String
  public let startedAt: String
  public let completedAt: String
  public let status: TaskBoardOrchestratorRunStatus
  public let dryRun: Bool
  public let sync: TaskBoardSyncSummary
  public let audit: TaskBoardAuditSummary
  public let dispatch: TaskBoardOrchestratorDispatchOutcome?
  public let evaluation: TaskBoardOrchestratorEvaluationOutcome?
  public let error: String?
  public let policyTraceIds: [String]

  public init(
    runId: String,
    startedAt: String,
    completedAt: String,
    status: TaskBoardOrchestratorRunStatus,
    dryRun: Bool,
    sync: TaskBoardSyncSummary,
    audit: TaskBoardAuditSummary,
    dispatch: TaskBoardOrchestratorDispatchOutcome? = nil,
    evaluation: TaskBoardOrchestratorEvaluationOutcome? = nil,
    error: String? = nil,
    policyTraceIds: [String] = []
  ) {
    self.runId = runId
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.status = status
    self.dryRun = dryRun
    self.sync = sync
    self.audit = audit
    self.dispatch = dispatch
    self.evaluation = evaluation
    self.error = error
    self.policyTraceIds = policyTraceIds
  }
}

extension TaskBoardOrchestratorRunSummary {
  enum CodingKeys: String, CodingKey {
    case runId
    case startedAt
    case completedAt
    case status
    case dryRun
    case sync
    case audit
    case dispatch
    case evaluation
    case error
    case policyTraceIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      runId: try container.decode(String.self, forKey: .runId),
      startedAt: try container.decode(String.self, forKey: .startedAt),
      completedAt: try container.decode(String.self, forKey: .completedAt),
      status: try container.decode(TaskBoardOrchestratorRunStatus.self, forKey: .status),
      dryRun: try container.decode(Bool.self, forKey: .dryRun),
      sync: try container.decode(TaskBoardSyncSummary.self, forKey: .sync),
      audit: try container.decode(TaskBoardAuditSummary.self, forKey: .audit),
      dispatch: try container.decodeIfPresent(
        TaskBoardOrchestratorDispatchOutcome.self,
        forKey: .dispatch
      ),
      evaluation: try container.decodeIfPresent(
        TaskBoardOrchestratorEvaluationOutcome.self,
        forKey: .evaluation
      ),
      error: try container.decodeIfPresent(String.self, forKey: .error),
      policyTraceIds: try container.decodeIfPresent([String].self, forKey: .policyTraceIds) ?? []
    )
  }
}

public struct TaskBoardWorkflowExecutionCount: Codable, Equatable, Sendable {
  public let status: TaskBoardWorkflowStatus
  public let count: Int

  public init(status: TaskBoardWorkflowStatus, count: Int) {
    self.status = status
    self.count = count
  }
}

public struct TaskBoardOrchestratorStatus: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let running: Bool
  public let stepMode: Bool
  public let heldDispatches: TaskBoardHeldDispatchSummary
  public let currentTick: TaskBoardOrchestratorTickInfo?
  public let lastRun: TaskBoardOrchestratorRunSummary?
  public let workflowExecutionCounts: [TaskBoardWorkflowExecutionCount]
  public let automation: TaskBoardAutomationSnapshot?
  public let settings: TaskBoardOrchestratorSettings

  public init(
    enabled: Bool,
    running: Bool,
    stepMode: Bool = false,
    heldDispatches: TaskBoardHeldDispatchSummary = TaskBoardHeldDispatchSummary(),
    currentTick: TaskBoardOrchestratorTickInfo? = nil,
    lastRun: TaskBoardOrchestratorRunSummary? = nil,
    workflowExecutionCounts: [TaskBoardWorkflowExecutionCount] = [],
    automation: TaskBoardAutomationSnapshot? = nil,
    settings: TaskBoardOrchestratorSettings
  ) {
    self.enabled = enabled
    self.running = running
    self.stepMode = stepMode
    self.heldDispatches = heldDispatches
    self.currentTick = currentTick
    self.lastRun = lastRun
    self.workflowExecutionCounts = workflowExecutionCounts
    self.automation = automation
    self.settings = settings
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case running
    case stepMode
    case heldDispatches
    case currentTick
    case lastRun
    case workflowExecutionCounts
    case automation
    case settings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decode(Bool.self, forKey: .enabled),
      running: try container.decode(Bool.self, forKey: .running),
      stepMode: try container.decodeIfPresent(Bool.self, forKey: .stepMode) ?? false,
      heldDispatches: try container.decodeIfPresent(
        TaskBoardHeldDispatchSummary.self,
        forKey: .heldDispatches
      ) ?? TaskBoardHeldDispatchSummary(),
      currentTick: try container.decodeIfPresent(
        TaskBoardOrchestratorTickInfo.self,
        forKey: .currentTick
      ),
      lastRun: try container.decodeIfPresent(
        TaskBoardOrchestratorRunSummary.self,
        forKey: .lastRun
      ),
      workflowExecutionCounts: try container.decode(
        [TaskBoardWorkflowExecutionCount].self,
        forKey: .workflowExecutionCounts
      ),
      automation: try container.decodeIfPresent(
        TaskBoardAutomationSnapshot.self,
        forKey: .automation
      ),
      settings: try container.decode(TaskBoardOrchestratorSettings.self, forKey: .settings)
    )
  }
}

extension TaskBoardOrchestratorStatus {
  var withoutAutomationSnapshot: TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: enabled,
      running: running,
      stepMode: stepMode,
      heldDispatches: heldDispatches,
      currentTick: currentTick,
      lastRun: lastRun,
      workflowExecutionCounts: workflowExecutionCounts,
      automation: nil,
      settings: settings
    )
  }
}

public typealias TaskBoardOrchestratorRunOnceResponse = TaskBoardOrchestratorStatus
