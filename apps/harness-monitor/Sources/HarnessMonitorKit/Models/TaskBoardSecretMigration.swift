import Foundation

/// A stored secret that can be carried from the previously connected daemon to
/// the newly connected one.
public enum TaskBoardSecretKind: Hashable, Sendable {
  case githubGlobalToken
  case openRouterToken
  case sshKey
  case signingSSHKey
  case gpgKey
  case repositoryGitHubToken(String)
  case repositorySSHKey(String)
  case repositorySigningSSHKey(String)
  case repositoryGPGKey(String)

  public var id: String {
    switch self {
    case .githubGlobalToken: "github-global-token"
    case .openRouterToken: "openrouter-token"
    case .sshKey: "ssh-key"
    case .signingSSHKey: "signing-ssh-key"
    case .gpgKey: "gpg-key"
    case .repositoryGitHubToken(let repo): "repo-github-token:\(repo)"
    case .repositorySSHKey(let repo): "repo-ssh-key:\(repo)"
    case .repositorySigningSSHKey(let repo): "repo-signing-ssh-key:\(repo)"
    case .repositoryGPGKey(let repo): "repo-gpg-key:\(repo)"
    }
  }

  /// Short secret name, shared between the global and per-repository variants.
  public var title: String {
    switch self {
    case .githubGlobalToken, .repositoryGitHubToken: "GitHub token"
    case .openRouterToken: "OpenRouter token"
    case .sshKey, .repositorySSHKey: "SSH key"
    case .signingSSHKey, .repositorySigningSSHKey: "Signing SSH key"
    case .gpgKey, .repositoryGPGKey: "GPG key"
    }
  }

  /// The repository slug for a per-repository secret, or `nil` for a global one.
  public var repository: String? {
    switch self {
    case .repositoryGitHubToken(let repo),
      .repositorySSHKey(let repo),
      .repositorySigningSSHKey(let repo),
      .repositoryGPGKey(let repo):
      repo
    default:
      nil
    }
  }

  /// Scope label shown next to the title in the review list.
  public var scopeLabel: String {
    repository ?? "Global"
  }
}

/// One secret offered in the connection-time migration review.
public struct TaskBoardSecretMigrationItem: Identifiable, Equatable, Sendable {
  public enum Disposition: Equatable, Sendable {
    /// The new daemon has no value for this secret; carrying it over is safe
    /// and offered on by default.
    case carryOver
    /// The new daemon already holds a different value; the user must choose
    /// whether to keep it or replace it with the previous daemon's.
    case conflict
  }

  public let kind: TaskBoardSecretKind
  public let disposition: Disposition

  public init(kind: TaskBoardSecretKind, disposition: Disposition) {
    self.kind = kind
    self.disposition = disposition
  }

  public var id: String { kind.id }
  public var title: String { kind.title }
  public var scopeLabel: String { kind.scopeLabel }
}

/// Per-secret decisions collected from the review. A `true` value writes the
/// previous daemon's value into the new scope (carry over, or replace on a
/// conflict); a missing or `false` value leaves the new daemon's value alone.
public typealias TaskBoardSecretMigrationSelections = [TaskBoardSecretKind: Bool]
