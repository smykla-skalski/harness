import Foundation

public struct TaskBoardGitRuntimeConfig: Codable, Equatable, Sendable {
  public let global: TaskBoardGitRuntimeProfile
  public let repositoryOverrides: [TaskBoardGitRepositoryOverride]

  public init(
    global: TaskBoardGitRuntimeProfile = TaskBoardGitRuntimeProfile(),
    repositoryOverrides: [TaskBoardGitRepositoryOverride] = []
  ) {
    self.global = global
    self.repositoryOverrides = repositoryOverrides
  }
}

public struct TaskBoardGitRuntimeProfile: Codable, Equatable, Sendable {
  public let authorName: String?
  public let authorEmail: String?
  public let sshKeyPath: String?
  public let signing: TaskBoardGitSigningConfig

  public init(
    authorName: String? = nil,
    authorEmail: String? = nil,
    sshKeyPath: String? = nil,
    signing: TaskBoardGitSigningConfig = TaskBoardGitSigningConfig()
  ) {
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.signing = signing
  }
}

public struct TaskBoardGitSigningConfig: Codable, Equatable, Sendable {
  public let mode: TaskBoardGitSigningMode
  public let sshKeyPath: String?
  public let gpgKeyId: String?
  public let gpgPrivateKeyPath: String?
  public let gpgPrivateKeyPassphrase: String?

  public init(
    mode: TaskBoardGitSigningMode = .none,
    sshKeyPath: String? = nil,
    gpgKeyId: String? = nil,
    gpgPrivateKeyPath: String? = nil,
    gpgPrivateKeyPassphrase: String? = nil
  ) {
    self.mode = mode
    self.sshKeyPath = sshKeyPath
    self.gpgKeyId = gpgKeyId
    self.gpgPrivateKeyPath = gpgPrivateKeyPath
    self.gpgPrivateKeyPassphrase = gpgPrivateKeyPassphrase
  }
}

public enum TaskBoardGitSigningMode: String, Codable, CaseIterable, Identifiable, Hashable,
  Sendable
{
  case none
  case ssh
  case gpg

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "None"
    case .ssh: "SSH"
    case .gpg: "GPG"
    }
  }
}

public struct TaskBoardGitRepositoryOverride: Codable, Equatable, Sendable {
  public let repository: String
  public let profile: TaskBoardGitRuntimeProfile

  public init(
    repository: String,
    profile: TaskBoardGitRuntimeProfile = TaskBoardGitRuntimeProfile()
  ) {
    self.repository = repository
    self.profile = profile
  }
}

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
  public let credentials: TaskBoardGitHubCredentialSnapshot

  public init(
    orchestratorSettings: TaskBoardOrchestratorSettings,
    runtimeConfig: TaskBoardGitRuntimeConfig,
    credentials: TaskBoardGitHubCredentialSnapshot
  ) {
    self.orchestratorSettings = orchestratorSettings
    self.runtimeConfig = runtimeConfig
    self.credentials = credentials
  }
}
