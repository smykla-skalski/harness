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

  enum CodingKeys: String, CodingKey {
    case global
    case repositoryOverrides
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      global: try container.decodeIfPresent(TaskBoardGitRuntimeProfile.self, forKey: .global)
        ?? TaskBoardGitRuntimeProfile(),
      repositoryOverrides: try container.decodeIfPresent(
        [TaskBoardGitRepositoryOverride].self,
        forKey: .repositoryOverrides
      ) ?? []
    )
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

  enum CodingKeys: String, CodingKey {
    case authorName
    case authorEmail
    case sshKeyPath
    case signing
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      authorName: try container.decodeIfPresent(String.self, forKey: .authorName),
      authorEmail: try container.decodeIfPresent(String.self, forKey: .authorEmail),
      sshKeyPath: try container.decodeIfPresent(String.self, forKey: .sshKeyPath),
      signing: try container.decodeIfPresent(TaskBoardGitSigningConfig.self, forKey: .signing)
        ?? TaskBoardGitSigningConfig()
    )
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

  enum CodingKeys: String, CodingKey {
    case mode
    case sshKeyPath
    case gpgKeyId
    case gpgPrivateKeyPath
    case gpgPrivateKeyPassphrase
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mode: try container.decodeIfPresent(TaskBoardGitSigningMode.self, forKey: .mode) ?? .none,
      sshKeyPath: try container.decodeIfPresent(String.self, forKey: .sshKeyPath),
      gpgKeyId: try container.decodeIfPresent(String.self, forKey: .gpgKeyId),
      gpgPrivateKeyPath: try container.decodeIfPresent(String.self, forKey: .gpgPrivateKeyPath),
      gpgPrivateKeyPassphrase: try container.decodeIfPresent(
        String.self,
        forKey: .gpgPrivateKeyPassphrase
      )
    )
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

  enum CodingKeys: String, CodingKey {
    case repository
    case profile
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      repository: try container.decode(String.self, forKey: .repository),
      profile: try container.decodeIfPresent(TaskBoardGitRuntimeProfile.self, forKey: .profile)
        ?? TaskBoardGitRuntimeProfile()
    )
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
