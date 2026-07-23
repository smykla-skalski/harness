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

public struct TaskBoardOrchestratorRunSummary: Codable, Equatable, Sendable {
  public let runId: String
  public let startedAt: String
  public let completedAt: String
  public let status: TaskBoardOrchestratorRunStatus
  public let dryRun: Bool
  public let sync: TaskBoardSyncSummary
  public let audit: TaskBoardAuditSummary
  public let dispatch: TaskBoardDispatchSummary?
  public let evaluation: TaskBoardEvaluationSummary?
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
    dispatch: TaskBoardDispatchSummary? = nil,
    evaluation: TaskBoardEvaluationSummary? = nil,
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
      dispatch: try container.decodeIfPresent(TaskBoardDispatchSummary.self, forKey: .dispatch),
      evaluation: try container.decodeIfPresent(
        TaskBoardEvaluationSummary.self,
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
