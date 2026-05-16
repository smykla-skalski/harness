import Foundation

public struct TaskBoardGitSigningVerifyRequest: Codable, Equatable, Sendable {
  public let repository: String?

  public init(repository: String? = nil) {
    self.repository = repository
  }
}

public enum TaskBoardGitSigningVerifyResponse: Codable, Equatable, Sendable {
  case skipped
  case signed(mode: String, signatureKind: String)
  case failed(message: String)

  enum CodingKeys: String, CodingKey {
    case outcome
    case mode
    case signatureKind
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let outcome = try container.decode(String.self, forKey: .outcome)
    switch outcome {
    case "skipped":
      self = .skipped
    case "signed":
      self = .signed(
        mode: try container.decode(String.self, forKey: .mode),
        signatureKind: try container.decode(String.self, forKey: .signatureKind)
      )
    case "failed":
      self = .failed(message: try container.decode(String.self, forKey: .message))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .outcome,
        in: container,
        debugDescription: "unknown signing verify outcome \(outcome)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .skipped:
      try container.encode("skipped", forKey: .outcome)
    case .signed(let mode, let signatureKind):
      try container.encode("signed", forKey: .outcome)
      try container.encode(mode, forKey: .mode)
      try container.encode(signatureKind, forKey: .signatureKind)
    case .failed(let message):
      try container.encode("failed", forKey: .outcome)
      try container.encode(message, forKey: .message)
    }
  }
}

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
  public let sshPrivateKey: String?
  public let sshPrivateKeyPassphrase: String?
  public let sshPrivateKeyConfigured: Bool
  public let sshPrivateKeyPassphraseConfigured: Bool
  public let signing: TaskBoardGitSigningConfig

  public init(
    authorName: String? = nil,
    authorEmail: String? = nil,
    sshKeyPath: String? = nil,
    sshPrivateKey: String? = nil,
    sshPrivateKeyPassphrase: String? = nil,
    sshPrivateKeyConfigured: Bool = false,
    sshPrivateKeyPassphraseConfigured: Bool = false,
    signing: TaskBoardGitSigningConfig = TaskBoardGitSigningConfig()
  ) {
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.sshPrivateKey = sshPrivateKey
    self.sshPrivateKeyPassphrase = sshPrivateKeyPassphrase
    self.sshPrivateKeyConfigured = sshPrivateKeyConfigured
    self.sshPrivateKeyPassphraseConfigured = sshPrivateKeyPassphraseConfigured
    self.signing = signing
  }

  enum CodingKeys: String, CodingKey {
    case authorName
    case authorEmail
    case sshKeyPath
    case sshPrivateKey
    case sshPrivateKeyPassphrase
    case sshPrivateKeyConfigured
    case sshPrivateKeyPassphraseConfigured
    case signing
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      authorName: try container.decodeIfPresent(String.self, forKey: .authorName),
      authorEmail: try container.decodeIfPresent(String.self, forKey: .authorEmail),
      sshKeyPath: try container.decodeIfPresent(String.self, forKey: .sshKeyPath),
      sshPrivateKey: try container.decodeIfPresent(String.self, forKey: .sshPrivateKey),
      sshPrivateKeyPassphrase: try container.decodeIfPresent(
        String.self,
        forKey: .sshPrivateKeyPassphrase
      ),
      sshPrivateKeyConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .sshPrivateKeyConfigured
      ) ?? false,
      sshPrivateKeyPassphraseConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .sshPrivateKeyPassphraseConfigured
      ) ?? false,
      signing: try container.decodeIfPresent(TaskBoardGitSigningConfig.self, forKey: .signing)
        ?? TaskBoardGitSigningConfig()
    )
  }
}

public struct TaskBoardGitSigningConfig: Codable, Equatable, Sendable {
  public let mode: TaskBoardGitSigningMode
  public let sshKeyPath: String?
  public let sshPrivateKey: String?
  public let sshPrivateKeyPassphrase: String?
  public let gpgKeyId: String?
  public let gpgPrivateKeyPath: String?
  public let gpgPrivateKey: String?
  public let gpgPrivateKeyPassphrase: String?
  public let sshPrivateKeyConfigured: Bool
  public let sshPrivateKeyPassphraseConfigured: Bool
  public let gpgPrivateKeyConfigured: Bool
  public let gpgPrivateKeyPassphraseConfigured: Bool

  public init(
    mode: TaskBoardGitSigningMode = .none,
    sshKeyPath: String? = nil,
    sshPrivateKey: String? = nil,
    sshPrivateKeyPassphrase: String? = nil,
    gpgKeyId: String? = nil,
    gpgPrivateKeyPath: String? = nil,
    gpgPrivateKey: String? = nil,
    gpgPrivateKeyPassphrase: String? = nil,
    sshPrivateKeyConfigured: Bool = false,
    sshPrivateKeyPassphraseConfigured: Bool = false,
    gpgPrivateKeyConfigured: Bool = false,
    gpgPrivateKeyPassphraseConfigured: Bool = false
  ) {
    self.mode = mode
    self.sshKeyPath = sshKeyPath
    self.sshPrivateKey = sshPrivateKey
    self.sshPrivateKeyPassphrase = sshPrivateKeyPassphrase
    self.gpgKeyId = gpgKeyId
    self.gpgPrivateKeyPath = gpgPrivateKeyPath
    self.gpgPrivateKey = gpgPrivateKey
    self.gpgPrivateKeyPassphrase = gpgPrivateKeyPassphrase
    self.sshPrivateKeyConfigured = sshPrivateKeyConfigured
    self.sshPrivateKeyPassphraseConfigured = sshPrivateKeyPassphraseConfigured
    self.gpgPrivateKeyConfigured = gpgPrivateKeyConfigured
    self.gpgPrivateKeyPassphraseConfigured = gpgPrivateKeyPassphraseConfigured
  }

  enum CodingKeys: String, CodingKey {
    case mode
    case sshKeyPath
    case sshPrivateKey
    case sshPrivateKeyPassphrase
    case gpgKeyId
    case gpgPrivateKeyPath
    case gpgPrivateKey
    case gpgPrivateKeyPassphrase
    case sshPrivateKeyConfigured
    case sshPrivateKeyPassphraseConfigured
    case gpgPrivateKeyConfigured
    case gpgPrivateKeyPassphraseConfigured
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mode: try container.decodeIfPresent(TaskBoardGitSigningMode.self, forKey: .mode) ?? .none,
      sshKeyPath: try container.decodeIfPresent(String.self, forKey: .sshKeyPath),
      sshPrivateKey: try container.decodeIfPresent(String.self, forKey: .sshPrivateKey),
      sshPrivateKeyPassphrase: try container.decodeIfPresent(
        String.self,
        forKey: .sshPrivateKeyPassphrase
      ),
      gpgKeyId: try container.decodeIfPresent(String.self, forKey: .gpgKeyId),
      gpgPrivateKeyPath: try container.decodeIfPresent(String.self, forKey: .gpgPrivateKeyPath),
      gpgPrivateKey: try container.decodeIfPresent(String.self, forKey: .gpgPrivateKey),
      gpgPrivateKeyPassphrase: try container.decodeIfPresent(
        String.self,
        forKey: .gpgPrivateKeyPassphrase
      ),
      sshPrivateKeyConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .sshPrivateKeyConfigured
      ) ?? false,
      sshPrivateKeyPassphraseConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .sshPrivateKeyPassphraseConfigured
      ) ?? false,
      gpgPrivateKeyConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .gpgPrivateKeyConfigured
      ) ?? false,
      gpgPrivateKeyPassphraseConfigured: try container.decodeIfPresent(
        Bool.self,
        forKey: .gpgPrivateKeyPassphraseConfigured
      ) ?? false
    )
  }
}

public enum TaskBoardGitSigningMode: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case none
  case ssh
  case gpg
  case unknown(String)

  public static let allCases: [Self] = [.none, .ssh, .gpg]

  public var rawValue: String {
    switch self {
    case .none: "none"
    case .ssh: "ssh"
    case .gpg: "gpg"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "none": self = .none
    case "ssh": self = .ssh
    case "gpg": self = .gpg
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "None"
    case .ssh: "SSH"
    case .gpg: "GPG"
    case .unknown(let raw): raw
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
  public let identityDefaults: TaskBoardGitIdentityDefaults

  public init(
    orchestratorSettings: TaskBoardOrchestratorSettings,
    runtimeConfig: TaskBoardGitRuntimeConfig,
    githubCredentials: TaskBoardGitHubCredentialSnapshot,
    todoistCredentials: TaskBoardTodoistCredentialSnapshot = TaskBoardTodoistCredentialSnapshot(),
    identityDefaults: TaskBoardGitIdentityDefaults = TaskBoardGitIdentityDefaults()
  ) {
    self.orchestratorSettings = orchestratorSettings
    self.runtimeConfig = runtimeConfig
    self.githubCredentials = githubCredentials
    self.todoistCredentials = todoistCredentials
    self.identityDefaults = identityDefaults
  }
}
