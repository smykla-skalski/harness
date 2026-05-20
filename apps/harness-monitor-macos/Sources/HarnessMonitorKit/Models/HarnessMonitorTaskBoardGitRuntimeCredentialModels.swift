import Foundation

public struct TaskBoardGitHubTokensSyncRequest: Codable, Equatable, Sendable {
  public let globalToken: String?
  public let repositoryTokens: [TaskBoardGitHubRepositoryToken]

  public init(
    globalToken: String? = nil,
    repositoryTokens: [TaskBoardGitHubRepositoryToken] = []
  ) {
    self.globalToken = globalToken
    self.repositoryTokens = repositoryTokens
  }
}

public struct TaskBoardGitHubRepositoryToken: Codable, Equatable, Sendable {
  public let repository: String
  public let token: String

  public init(repository: String, token: String) {
    self.repository = repository
    self.token = token
  }
}

public struct TaskBoardGitHubTokensSyncResponse: Codable, Equatable, Sendable {
  public let globalTokenConfigured: Bool
  public let repositoryTokenCount: Int

  public init(globalTokenConfigured: Bool, repositoryTokenCount: Int) {
    self.globalTokenConfigured = globalTokenConfigured
    self.repositoryTokenCount = repositoryTokenCount
  }
}

public struct TaskBoardTodoistTokenSyncRequest: Codable, Equatable, Sendable {
  public let token: String?

  public init(token: String? = nil) {
    self.token = token
  }
}

public struct TaskBoardTodoistTokenSyncResponse: Codable, Equatable, Sendable {
  public let tokenConfigured: Bool

  public init(tokenConfigured: Bool) {
    self.tokenConfigured = tokenConfigured
  }
}

public struct TaskBoardTodoistCredentialSnapshot: Codable, Equatable, Sendable {
  public let token: String?

  public init(token: String? = nil) {
    self.token = token
  }

  public var syncRequest: TaskBoardTodoistTokenSyncRequest {
    TaskBoardTodoistTokenSyncRequest(token: token)
  }

  public var isEmpty: Bool {
    token == nil
  }
}

public struct TaskBoardOpenRouterTokenSyncRequest: Codable, Equatable, Sendable {
  public let token: String?

  public init(token: String? = nil) {
    self.token = token
  }
}

public struct TaskBoardOpenRouterTokenSyncResponse: Codable, Equatable, Sendable {
  public let tokenConfigured: Bool

  public init(tokenConfigured: Bool) {
    self.tokenConfigured = tokenConfigured
  }
}

public struct TaskBoardOpenRouterCredentialSnapshot: Codable, Equatable, Sendable {
  public let token: String?

  public init(token: String? = nil) {
    self.token = token
  }

  public var syncRequest: TaskBoardOpenRouterTokenSyncRequest {
    TaskBoardOpenRouterTokenSyncRequest(token: token)
  }

  public var isEmpty: Bool {
    token == nil
  }
}

public struct TaskBoardGitHubCredentialSnapshot: Codable, Equatable, Sendable {
  public let globalToken: String?
  public let repositoryTokens: [TaskBoardGitHubRepositoryToken]

  public init(
    globalToken: String? = nil,
    repositoryTokens: [TaskBoardGitHubRepositoryToken] = []
  ) {
    self.globalToken = globalToken
    self.repositoryTokens = repositoryTokens
  }

  public var syncRequest: TaskBoardGitHubTokensSyncRequest {
    TaskBoardGitHubTokensSyncRequest(
      globalToken: globalToken,
      repositoryTokens: repositoryTokens
    )
  }

  public var isEmpty: Bool {
    globalToken == nil && repositoryTokens.isEmpty
  }
}

public struct TaskBoardGitSettingsSnapshot: Equatable, Sendable {
  public let orchestratorSettings: TaskBoardOrchestratorSettings
  public let runtimeConfig: TaskBoardGitRuntimeConfig
  public let githubCredentials: TaskBoardGitHubCredentialSnapshot
  public let todoistCredentials: TaskBoardTodoistCredentialSnapshot
  public let openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot
  public let identityDefaults: TaskBoardGitIdentityDefaults

  public init(
    orchestratorSettings: TaskBoardOrchestratorSettings,
    runtimeConfig: TaskBoardGitRuntimeConfig,
    githubCredentials: TaskBoardGitHubCredentialSnapshot,
    todoistCredentials: TaskBoardTodoistCredentialSnapshot = TaskBoardTodoistCredentialSnapshot(),
    openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot =
      TaskBoardOpenRouterCredentialSnapshot(),
    identityDefaults: TaskBoardGitIdentityDefaults = TaskBoardGitIdentityDefaults()
  ) {
    self.orchestratorSettings = orchestratorSettings
    self.runtimeConfig = runtimeConfig
    self.githubCredentials = githubCredentials
    self.todoistCredentials = todoistCredentials
    self.openRouterCredentials = openRouterCredentials
    self.identityDefaults = identityDefaults
  }
}
