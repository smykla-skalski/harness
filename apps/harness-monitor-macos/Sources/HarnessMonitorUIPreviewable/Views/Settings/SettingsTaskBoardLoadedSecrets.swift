import Foundation
import HarnessMonitorKit

/// Snapshot of plaintext secret material captured when a settings view is
/// hydrated. The draft uses this to re-emit `.configured` fields back to the
/// daemon without the user having to retype, while still keeping the secret
/// strings out of the user-visible bindings.
struct TaskBoardLoadedSecrets: Equatable {
  var globalSSHPrivateKey: String?
  var globalSSHPrivateKeyPassphrase: String?
  var globalSigningSSHPrivateKey: String?
  var globalSigningSSHPrivateKeyPassphrase: String?
  var globalGPGPrivateKey: String?
  var globalGPGPrivateKeyPassphrase: String?
  var globalGitHubToken: String?
  var todoistToken: String?
  var repositoryRuntime: [String: TaskBoardLoadedRepositorySecrets] = [:]
  var repositoryTokens: [String: String] = [:]

  init() {}

  init(snapshot: TaskBoardGitSettingsSnapshot) {
    globalSSHPrivateKey = snapshot.runtimeConfig.global.sshPrivateKey
    globalSSHPrivateKeyPassphrase = snapshot.runtimeConfig.global.sshPrivateKeyPassphrase
    globalSigningSSHPrivateKey = snapshot.runtimeConfig.global.signing.sshPrivateKey
    globalSigningSSHPrivateKeyPassphrase =
      snapshot.runtimeConfig.global.signing.sshPrivateKeyPassphrase
    globalGPGPrivateKey = snapshot.runtimeConfig.global.signing.gpgPrivateKey
    globalGPGPrivateKeyPassphrase = snapshot.runtimeConfig.global.signing.gpgPrivateKeyPassphrase
    globalGitHubToken = snapshot.githubCredentials.globalToken
    todoistToken = snapshot.todoistCredentials.token

    repositoryRuntime = Dictionary(
      uniqueKeysWithValues: snapshot.runtimeConfig.repositoryOverrides.map { override in
        (
          override.repository.lowercased(),
          TaskBoardLoadedRepositorySecrets(profile: override.profile)
        )
      }
    )
    repositoryTokens = Dictionary(
      uniqueKeysWithValues: snapshot.githubCredentials.repositoryTokens.map { token in
        (token.repository.lowercased(), token.token)
      }
    )
  }

  func repositorySecrets(for repository: String) -> TaskBoardLoadedRepositorySecrets {
    repositoryRuntime[repository.lowercased()] ?? TaskBoardLoadedRepositorySecrets()
  }

  func repositoryToken(for repository: String) -> String? {
    repositoryTokens[repository.lowercased()]
  }
}

struct TaskBoardLoadedRepositorySecrets: Equatable {
  var sshPrivateKey: String?
  var sshPrivateKeyPassphrase: String?
  var signingSSHPrivateKey: String?
  var signingSSHPrivateKeyPassphrase: String?
  var gpgPrivateKey: String?
  var gpgPrivateKeyPassphrase: String?

  init() {}

  init(profile: TaskBoardGitRuntimeProfile) {
    sshPrivateKey = profile.sshPrivateKey
    sshPrivateKeyPassphrase = profile.sshPrivateKeyPassphrase
    signingSSHPrivateKey = profile.signing.sshPrivateKey
    signingSSHPrivateKeyPassphrase = profile.signing.sshPrivateKeyPassphrase
    gpgPrivateKey = profile.signing.gpgPrivateKey
    gpgPrivateKeyPassphrase = profile.signing.gpgPrivateKeyPassphrase
  }
}
