import Foundation

public struct TaskBoardGitHubInboxConfig: Codable, Equatable, Sendable {
  public let repositories: [String]
  public let labelFilter: [String]

  public init(repositories: [String] = [], labelFilter: [String] = []) {
    self.repositories = repositories
    self.labelFilter = labelFilter
  }

  enum CodingKeys: String, CodingKey {
    case repositories
    case labelFilter
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      repositories: try container.decodeIfPresent([String].self, forKey: .repositories) ?? [],
      labelFilter: try container.decodeIfPresent([String].self, forKey: .labelFilter) ?? []
    )
  }
}

public struct TaskBoardTodoistInboxConfig: Codable, Equatable, Sendable {
  public let projectFilter: [String]

  public init(projectFilter: [String] = []) {
    self.projectFilter = projectFilter
  }

  enum CodingKeys: String, CodingKey {
    case projectFilter
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      projectFilter: try container.decodeIfPresent([String].self, forKey: .projectFilter) ?? []
    )
  }
}

public struct TaskBoardGitHubProjectConfig: Codable, Equatable, Sendable {
  public let owner: String
  public let repo: String
  public let checkoutPath: String
  public let defaultBranch: String
  public let branchPrefix: String
  public let mergeMethod: TaskBoardGitHubMergeMethod
  public let labels: TaskBoardGitHubAutomationLabels
  public let protectedPaths: [TaskBoardProtectedPathRule]
  public let requestedReviewers: TaskBoardGitHubRequestedReviewers
  public let enabledAutomations: TaskBoardGitHubAutomationToggles

  public init(
    owner: String = "",
    repo: String = "",
    checkoutPath: String = "",
    defaultBranch: String = "main",
    branchPrefix: String = "c/",
    mergeMethod: TaskBoardGitHubMergeMethod = .squash,
    labels: TaskBoardGitHubAutomationLabels = TaskBoardGitHubAutomationLabels(),
    protectedPaths: [TaskBoardProtectedPathRule] = [],
    requestedReviewers: TaskBoardGitHubRequestedReviewers = TaskBoardGitHubRequestedReviewers(),
    enabledAutomations: TaskBoardGitHubAutomationToggles = TaskBoardGitHubAutomationToggles()
  ) {
    self.owner = owner
    self.repo = repo
    self.checkoutPath = checkoutPath
    self.defaultBranch = defaultBranch
    self.branchPrefix = branchPrefix
    self.mergeMethod = mergeMethod
    self.labels = labels
    self.protectedPaths = protectedPaths
    self.requestedReviewers = requestedReviewers
    self.enabledAutomations = enabledAutomations
  }

  enum CodingKeys: String, CodingKey {
    case owner
    case repo
    case checkoutPath
    case defaultBranch
    case branchPrefix
    case mergeMethod
    case labels
    case protectedPaths
    case requestedReviewers
    case enabledAutomations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      owner: try container.decodeIfPresent(String.self, forKey: .owner) ?? "",
      repo: try container.decodeIfPresent(String.self, forKey: .repo) ?? "",
      checkoutPath: try container.decodeIfPresent(String.self, forKey: .checkoutPath) ?? "",
      defaultBranch: try container.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main",
      branchPrefix: try container.decodeIfPresent(String.self, forKey: .branchPrefix) ?? "c/",
      mergeMethod: try container.decodeIfPresent(
        TaskBoardGitHubMergeMethod.self,
        forKey: .mergeMethod
      ) ?? .squash,
      labels: try container.decodeIfPresent(TaskBoardGitHubAutomationLabels.self, forKey: .labels)
        ?? TaskBoardGitHubAutomationLabels(),
      protectedPaths: try container.decodeIfPresent(
        [TaskBoardProtectedPathRule].self,
        forKey: .protectedPaths
      ) ?? [],
      requestedReviewers: try container.decodeIfPresent(
        TaskBoardGitHubRequestedReviewers.self,
        forKey: .requestedReviewers
      ) ?? TaskBoardGitHubRequestedReviewers(),
      enabledAutomations: try container.decodeIfPresent(
        TaskBoardGitHubAutomationToggles.self,
        forKey: .enabledAutomations
      ) ?? TaskBoardGitHubAutomationToggles()
    )
  }
}

public enum TaskBoardGitHubMergeMethod: String, Codable, CaseIterable, Identifiable, Hashable,
  Sendable
{
  case squash
  case merge
  case rebase

  public var id: String { rawValue }
}

public struct TaskBoardGitHubAutomationLabels: Codable, Equatable, Sendable {
  public let managed: String
  public let autoMerge: String
  public let needsHuman: String
  public let protectedPath: String

  public init(
    managed: String = "harness:managed",
    autoMerge: String = "harness:auto-merge",
    needsHuman: String = "harness:needs-human",
    protectedPath: String = "harness:protected-path"
  ) {
    self.managed = managed
    self.autoMerge = autoMerge
    self.needsHuman = needsHuman
    self.protectedPath = protectedPath
  }

  enum CodingKeys: String, CodingKey {
    case managed
    case autoMerge
    case needsHuman
    case protectedPath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      managed: try container.decodeIfPresent(String.self, forKey: .managed) ?? "harness:managed",
      autoMerge: try container.decodeIfPresent(String.self, forKey: .autoMerge)
        ?? "harness:auto-merge",
      needsHuman: try container.decodeIfPresent(String.self, forKey: .needsHuman)
        ?? "harness:needs-human",
      protectedPath: try container.decodeIfPresent(String.self, forKey: .protectedPath)
        ?? "harness:protected-path"
    )
  }
}

public struct TaskBoardGitHubRequestedReviewers: Codable, Equatable, Sendable {
  public let reviewers: [String]
  public let teamReviewers: [String]

  public init(
    reviewers: [String] = [],
    teamReviewers: [String] = []
  ) {
    self.reviewers = reviewers
    self.teamReviewers = teamReviewers
  }

  enum CodingKeys: String, CodingKey {
    case reviewers
    case teamReviewers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      reviewers: try container.decodeIfPresent([String].self, forKey: .reviewers) ?? [],
      teamReviewers: try container.decodeIfPresent([String].self, forKey: .teamReviewers) ?? []
    )
  }
}

public struct TaskBoardGitHubAutomationToggles: Codable, Equatable, Sendable {
  public let enabled: [TaskBoardGitHubAutomation]

  public init(
    enabled: [TaskBoardGitHubAutomation] = [
      .syncTaskBoard,
      .createBranch,
      .openPullRequest,
      .watchChecks,
      .requestReview,
    ]
  ) {
    self.enabled = enabled
  }

  enum CodingKeys: String, CodingKey {
    case enabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      enabled: try container.decodeIfPresent(
        [TaskBoardGitHubAutomation].self,
        forKey: .enabled
      ) ?? [
        .syncTaskBoard,
        .createBranch,
        .openPullRequest,
        .watchChecks,
        .requestReview,
      ]
    )
  }
}

public enum TaskBoardGitHubAutomation: String, Codable, CaseIterable, Identifiable, Hashable,
  Sendable
{
  case syncTaskBoard = "sync_task_board"
  case createBranch = "create_branch"
  case openPullRequest = "open_pull_request"
  case watchChecks = "watch_checks"
  case requestReview = "request_review"
  case autoMerge = "auto_merge"

  public var id: String { rawValue }
}

public struct TaskBoardProtectedPathRule: Codable, Equatable, Sendable {
  public let pattern: String

  public init(pattern: String) {
    self.pattern = pattern
  }
}
