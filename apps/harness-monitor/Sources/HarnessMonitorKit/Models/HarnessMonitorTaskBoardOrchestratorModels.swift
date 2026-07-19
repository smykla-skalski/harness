import Foundation

public enum TaskBoardOrchestratorWorkflow: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case defaultTask
  case prFix
  case prReview
  case review
  case unknown(String)

  public static let allCases: [Self] = [
    .defaultTask,
    .prFix,
    .prReview,
    .review,
  ]

  public var rawValue: String {
    switch self {
    case .defaultTask: "default_task"
    case .prFix: "pr_fix"
    case .prReview: "pr_review"
    case .review: "review"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "default_task": self = .defaultTask
    case "pr_fix": self = .prFix
    case "pr_review": self = .prReview
    case "review": self = .review
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }
}

public struct TaskBoardOrchestratorSettings: Codable, Equatable, Sendable {
  public let stepMode: Bool
  public let enabledWorkflows: [TaskBoardOrchestratorWorkflow]
  public let dryRunDefault: Bool
  public let dispatchStatusFilter: TaskBoardStatus?
  public let projectDir: String?
  public let githubProject: TaskBoardGitHubProjectConfig
  public let githubInbox: TaskBoardGitHubInboxConfig
  public let todoistInbox: TaskBoardTodoistInboxConfig
  public let scheduling: TaskBoardAutomationSchedulingSettings
  public let retry: TaskBoardAutomationRetrySettings
  public let reviewers: TaskBoardReviewerSettings
  public let policyVersion: String

  public init(
    stepMode: Bool = false,
    enabledWorkflows: [TaskBoardOrchestratorWorkflow] = [],
    dryRunDefault: Bool = true,
    dispatchStatusFilter: TaskBoardStatus? = nil,
    projectDir: String? = nil,
    githubProject: TaskBoardGitHubProjectConfig = TaskBoardGitHubProjectConfig(),
    githubInbox: TaskBoardGitHubInboxConfig = TaskBoardGitHubInboxConfig(),
    todoistInbox: TaskBoardTodoistInboxConfig = TaskBoardTodoistInboxConfig(),
    scheduling: TaskBoardAutomationSchedulingSettings? = nil,
    retry: TaskBoardAutomationRetrySettings? = nil,
    reviewers: TaskBoardReviewerSettings? = nil,
    policyVersion: String
  ) {
    self.stepMode = stepMode
    self.enabledWorkflows = enabledWorkflows
    self.dryRunDefault = dryRunDefault
    self.dispatchStatusFilter = dispatchStatusFilter
    self.projectDir = projectDir
    self.githubProject = githubProject
    self.githubInbox = githubInbox
    self.todoistInbox = todoistInbox
    self.scheduling = scheduling ?? Self.defaultScheduling
    self.retry = retry ?? Self.defaultRetry
    self.reviewers = reviewers ?? Self.defaultReviewers
    self.policyVersion = policyVersion
  }

  enum CodingKeys: String, CodingKey {
    case stepMode
    case enabledWorkflows
    case dryRunDefault
    case dispatchStatusFilter
    case projectDir
    case githubProject
    case githubInbox
    case todoistInbox
    case scheduling
    case retry
    case reviewers
    case policyVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      stepMode: try container.decodeIfPresent(Bool.self, forKey: .stepMode) ?? false,
      enabledWorkflows: try container.decode(
        [TaskBoardOrchestratorWorkflow].self,
        forKey: .enabledWorkflows
      ),
      dryRunDefault: try container.decode(Bool.self, forKey: .dryRunDefault),
      dispatchStatusFilter: try container.decodeIfPresent(
        TaskBoardStatus.self,
        forKey: .dispatchStatusFilter
      ),
      projectDir: try container.decodeIfPresent(String.self, forKey: .projectDir),
      githubProject: try container.decode(
        TaskBoardGitHubProjectConfig.self,
        forKey: .githubProject
      ),
      githubInbox: try container.decodeIfPresent(
        TaskBoardGitHubInboxConfig.self,
        forKey: .githubInbox
      ) ?? TaskBoardGitHubInboxConfig(),
      todoistInbox: try container.decodeIfPresent(
        TaskBoardTodoistInboxConfig.self,
        forKey: .todoistInbox
      ) ?? TaskBoardTodoistInboxConfig(),
      scheduling: try container.decodeIfPresent(
        TaskBoardAutomationSchedulingSettings.self,
        forKey: .scheduling
      ),
      retry: try container.decodeIfPresent(
        TaskBoardAutomationRetrySettings.self,
        forKey: .retry
      ),
      reviewers: try container.decodeIfPresent(
        TaskBoardReviewerSettings.self,
        forKey: .reviewers
      ),
      policyVersion: try container.decode(String.self, forKey: .policyVersion)
    )
  }

  private static let defaultScheduling = TaskBoardAutomationSchedulingSettings(
    maxDispatchesPerRun: 1,
    maxConcurrentWorkflows: 1,
    reconcileIntervalSeconds: 60
  )

  private static let defaultRetry = TaskBoardAutomationRetrySettings(
    maxAttempts: 3,
    baseDelaySeconds: 30,
    multiplier: 4,
    maxDelaySeconds: 600,
    deterministicJitterPercent: 10
  )

  private static let defaultReviewers = TaskBoardReviewerSettings(
    reviewerCount: 1,
    requiredApprovals: 1,
    maxRevisionCycles: 3,
    profiles: [
      TaskBoardReviewerProfile(
        id: "default-code-reviewer",
        runtime: "codex",
        persona: "code-reviewer",
        agentMode: .evaluate
      )
    ]
  )
}

public struct TaskBoardOrchestratorSettingsUpdateRequest: Codable, Equatable, Sendable {
  public let stepMode: Bool?
  public let enabledWorkflows: [TaskBoardOrchestratorWorkflow]?
  public let dryRunDefault: Bool?
  public let dispatchStatusFilter: TaskBoardStatus?
  public let clearDispatchStatusFilter: Bool
  public let projectDir: String?
  public let clearProjectDir: Bool
  public let githubProject: TaskBoardGitHubProjectConfig?
  public let githubInbox: TaskBoardGitHubInboxConfig?
  public let todoistInbox: TaskBoardTodoistInboxConfig?
  public let policyVersion: String?

  public init(
    stepMode: Bool? = nil,
    enabledWorkflows: [TaskBoardOrchestratorWorkflow]? = nil,
    dryRunDefault: Bool? = nil,
    dispatchStatusFilter: TaskBoardStatus? = nil,
    clearDispatchStatusFilter: Bool = false,
    projectDir: String? = nil,
    clearProjectDir: Bool = false,
    githubProject: TaskBoardGitHubProjectConfig? = nil,
    githubInbox: TaskBoardGitHubInboxConfig? = nil,
    todoistInbox: TaskBoardTodoistInboxConfig? = nil,
    policyVersion: String? = nil
  ) {
    self.stepMode = stepMode
    self.enabledWorkflows = enabledWorkflows
    self.dryRunDefault = dryRunDefault
    self.dispatchStatusFilter = dispatchStatusFilter
    self.clearDispatchStatusFilter = clearDispatchStatusFilter
    self.projectDir = projectDir
    self.clearProjectDir = clearProjectDir
    self.githubProject = githubProject
    self.githubInbox = githubInbox
    self.todoistInbox = todoistInbox
    self.policyVersion = policyVersion
  }
}
