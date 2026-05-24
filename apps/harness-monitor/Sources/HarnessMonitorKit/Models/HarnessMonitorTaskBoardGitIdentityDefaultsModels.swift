import Foundation

public struct TaskBoardGitIdentityDefaults: Codable, Equatable, Sendable {
  public var gitConfig: TaskBoardGitConfigDefaults
  public var ghCli: TaskBoardGhCliDefaults
  public var discoveredSshKeys: [TaskBoardSshKeyDiscovery]
  public var envOverrides: TaskBoardEnvDefaults

  public init(
    gitConfig: TaskBoardGitConfigDefaults = .init(),
    ghCli: TaskBoardGhCliDefaults = .init(),
    discoveredSshKeys: [TaskBoardSshKeyDiscovery] = [],
    envOverrides: TaskBoardEnvDefaults = .init()
  ) {
    self.gitConfig = gitConfig
    self.ghCli = ghCli
    self.discoveredSshKeys = discoveredSshKeys
    self.envOverrides = envOverrides
  }

  enum CodingKeys: String, CodingKey {
    case gitConfig = "git_config"
    case ghCli = "gh_cli"
    case discoveredSshKeys = "discovered_ssh_keys"
    case envOverrides = "env_overrides"
  }
}

public struct TaskBoardGitConfigDefaults: Codable, Equatable, Sendable {
  public var userName: String?
  public var userEmail: String?
  public var userSigningkey: String?
  public var gpgFormat: String?
  public var commitGpgsign: Bool?
  public var coreSshCommand: String?

  public init(
    userName: String? = nil,
    userEmail: String? = nil,
    userSigningkey: String? = nil,
    gpgFormat: String? = nil,
    commitGpgsign: Bool? = nil,
    coreSshCommand: String? = nil
  ) {
    self.userName = userName
    self.userEmail = userEmail
    self.userSigningkey = userSigningkey
    self.gpgFormat = gpgFormat
    self.commitGpgsign = commitGpgsign
    self.coreSshCommand = coreSshCommand
  }

  enum CodingKeys: String, CodingKey {
    case userName = "user_name"
    case userEmail = "user_email"
    case userSigningkey = "user_signingkey"
    case gpgFormat = "gpg_format"
    case commitGpgsign = "commit_gpgsign"
    case coreSshCommand = "core_ssh_command"
  }
}

public struct TaskBoardGhCliDefaults: Codable, Equatable, Sendable {
  public var githubTokenPresent: Bool
  public var username: String?

  public init(githubTokenPresent: Bool = false, username: String? = nil) {
    self.githubTokenPresent = githubTokenPresent
    self.username = username
  }

  enum CodingKeys: String, CodingKey {
    case githubTokenPresent = "github_token_present"
    case username
  }
}

public struct TaskBoardSshKeyDiscovery: Codable, Equatable, Sendable, Identifiable {
  public var path: String
  public var mode: String
  public var format: String?
  public var warning: String?

  public var id: String { path }

  public init(
    path: String,
    mode: String,
    format: String? = nil,
    warning: String? = nil
  ) {
    self.path = path
    self.mode = mode
    self.format = format
    self.warning = warning
  }

  public var permissionsTooOpen: Bool {
    warning != nil
  }
}

public struct TaskBoardEnvDefaults: Codable, Equatable, Sendable {
  public var harnessGithubTokenPresent: Bool
  public var harnessTodoistTokenPresent: Bool

  public init(
    harnessGithubTokenPresent: Bool = false,
    harnessTodoistTokenPresent: Bool = false
  ) {
    self.harnessGithubTokenPresent = harnessGithubTokenPresent
    self.harnessTodoistTokenPresent = harnessTodoistTokenPresent
  }

  enum CodingKeys: String, CodingKey {
    case harnessGithubTokenPresent = "harness_github_token_present"
    case harnessTodoistTokenPresent = "harness_todoist_token_present"
  }
}
