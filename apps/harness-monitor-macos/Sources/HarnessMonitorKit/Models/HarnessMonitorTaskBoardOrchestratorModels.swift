import Foundation

public enum TaskBoardOrchestratorWorkflow: String, Codable, CaseIterable, Identifiable, Sendable {
  case defaultTask = "default_task"
  case prFix = "pr_fix"
  case prReview = "pr_review"
  case dependencyUpdate = "dependency_update"

  public var id: String { rawValue }
}

public struct TaskBoardOrchestratorSettings: Codable, Equatable, Sendable {
  public let enabledWorkflows: [TaskBoardOrchestratorWorkflow]
  public let dryRunDefault: Bool
  public let dispatchStatusFilter: TaskBoardStatus?
  public let projectDir: String?
  public let githubProject: TaskBoardGitHubProjectConfig
  public let policyVersion: String

  public init(
    enabledWorkflows: [TaskBoardOrchestratorWorkflow] = [],
    dryRunDefault: Bool = true,
    dispatchStatusFilter: TaskBoardStatus? = nil,
    projectDir: String? = nil,
    githubProject: TaskBoardGitHubProjectConfig = TaskBoardGitHubProjectConfig(),
    policyVersion: String
  ) {
    self.enabledWorkflows = enabledWorkflows
    self.dryRunDefault = dryRunDefault
    self.dispatchStatusFilter = dispatchStatusFilter
    self.projectDir = projectDir
    self.githubProject = githubProject
    self.policyVersion = policyVersion
  }
}

public struct TaskBoardOrchestratorSettingsUpdateRequest: Codable, Equatable, Sendable {
  public let enabledWorkflows: [TaskBoardOrchestratorWorkflow]?
  public let dryRunDefault: Bool?
  public let dispatchStatusFilter: TaskBoardStatus?
  public let clearDispatchStatusFilter: Bool
  public let projectDir: String?
  public let clearProjectDir: Bool
  public let githubProject: TaskBoardGitHubProjectConfig?
  public let policyVersion: String?

  public init(
    enabledWorkflows: [TaskBoardOrchestratorWorkflow]? = nil,
    dryRunDefault: Bool? = nil,
    dispatchStatusFilter: TaskBoardStatus? = nil,
    clearDispatchStatusFilter: Bool = false,
    projectDir: String? = nil,
    clearProjectDir: Bool = false,
    githubProject: TaskBoardGitHubProjectConfig? = nil,
    policyVersion: String? = nil
  ) {
    self.enabledWorkflows = enabledWorkflows
    self.dryRunDefault = dryRunDefault
    self.dispatchStatusFilter = dispatchStatusFilter
    self.clearDispatchStatusFilter = clearDispatchStatusFilter
    self.projectDir = projectDir
    self.clearProjectDir = clearProjectDir
    self.githubProject = githubProject
    self.policyVersion = policyVersion
  }
}

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
  public let currentTick: TaskBoardOrchestratorTickInfo?
  public let lastRun: TaskBoardOrchestratorRunSummary?
  public let workflowExecutionCounts: [TaskBoardWorkflowExecutionCount]
  public let settings: TaskBoardOrchestratorSettings

  public init(
    enabled: Bool,
    running: Bool,
    currentTick: TaskBoardOrchestratorTickInfo? = nil,
    lastRun: TaskBoardOrchestratorRunSummary? = nil,
    workflowExecutionCounts: [TaskBoardWorkflowExecutionCount] = [],
    settings: TaskBoardOrchestratorSettings
  ) {
    self.enabled = enabled
    self.running = running
    self.currentTick = currentTick
    self.lastRun = lastRun
    self.workflowExecutionCounts = workflowExecutionCounts
    self.settings = settings
  }
}

public typealias TaskBoardOrchestratorRunOnceResponse = TaskBoardOrchestratorStatus
