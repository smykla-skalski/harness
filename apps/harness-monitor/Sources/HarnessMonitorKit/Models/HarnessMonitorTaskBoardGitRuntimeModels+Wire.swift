import Foundation

// Wire maps for the git runtime config tree + drain-secrets response. Thin mirrors; the signing
// mode (TaskBoardGitSigningMode) is the decoder-agnostic hand open enum that rides through bare, so
// it carries across without a per-value map.

extension TaskBoardGitSigningConfig {
  init(wire: TaskBoardGitSigningConfigWire) {
    self.init(
      mode: wire.mode,
      sshKeyPath: wire.sshKeyPath,
      sshPrivateKey: wire.sshPrivateKey,
      sshPrivateKeyPassphrase: wire.sshPrivateKeyPassphrase,
      gpgKeyId: wire.gpgKeyId,
      gpgPrivateKeyPath: wire.gpgPrivateKeyPath,
      gpgPrivateKey: wire.gpgPrivateKey,
      gpgPrivateKeyPassphrase: wire.gpgPrivateKeyPassphrase,
      sshPrivateKeyConfigured: wire.sshPrivateKeyConfigured,
      sshPrivateKeyPassphraseConfigured: wire.sshPrivateKeyPassphraseConfigured,
      gpgPrivateKeyConfigured: wire.gpgPrivateKeyConfigured,
      gpgPrivateKeyPassphraseConfigured: wire.gpgPrivateKeyPassphraseConfigured
    )
  }
}

extension TaskBoardGitRuntimeProfile {
  init(wire: TaskBoardGitRuntimeProfileWire) {
    self.init(
      authorName: wire.authorName,
      authorEmail: wire.authorEmail,
      sshKeyPath: wire.sshKeyPath,
      sshPrivateKey: wire.sshPrivateKey,
      sshPrivateKeyPassphrase: wire.sshPrivateKeyPassphrase,
      sshPrivateKeyConfigured: wire.sshPrivateKeyConfigured,
      sshPrivateKeyPassphraseConfigured: wire.sshPrivateKeyPassphraseConfigured,
      signing: TaskBoardGitSigningConfig(wire: wire.signing)
    )
  }
}

extension TaskBoardGitRepositoryOverride {
  init(wire: TaskBoardGitRepositoryOverrideWire) {
    self.init(
      repository: wire.repository,
      profile: TaskBoardGitRuntimeProfile(wire: wire.profile)
    )
  }
}

extension TaskBoardGitRuntimeConfig {
  init(wire: TaskBoardGitRuntimeConfigWire) {
    self.init(
      global: TaskBoardGitRuntimeProfile(wire: wire.global),
      repositoryOverrides: wire.repositoryOverrides.map(TaskBoardGitRepositoryOverride.init(wire:))
    )
  }
}

extension TaskBoardGitRuntimeDrainSecretsResponse {
  init(wire: TaskBoardGitRuntimeDrainSecretsResponseWire) {
    self.init(
      drained: wire.drained,
      runtime: TaskBoardGitRuntimeConfig(wire: wire.runtime)
    )
  }
}
