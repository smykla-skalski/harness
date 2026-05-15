import Foundation

public struct TaskBoardGitHubInboxConfig: Codable, Equatable, Sendable {
  public let repositories: [String]

  public init(repositories: [String] = []) {
    self.repositories = repositories
  }

  enum CodingKeys: String, CodingKey {
    case repositories
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      repositories: try container.decodeIfPresent([String].self, forKey: .repositories) ?? []
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
