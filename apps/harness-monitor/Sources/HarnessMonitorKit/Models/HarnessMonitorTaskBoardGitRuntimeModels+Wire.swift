import Foundation

// Wire maps for the git runtime config tree + secret-handoff response. Thin mirrors; the signing
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

extension TaskBoardGitRuntimeSecretHandoffPrepareResponse {
  init(wire: TaskBoardGitRuntimeSecretHandoffPrepareResponseWire) {
    self.init(
      prepared: wire.prepared,
      migrationID: wire.migrationId,
      digest: wire.digest,
      runtime: TaskBoardGitRuntimeConfig(wire: wire.runtime)
    )
  }
}

extension TaskBoardGitSigningVerifyResponse {
  init(wire: TaskBoardGitSigningVerifyResponseWire) {
    switch wire {
    case .skipped:
      self = .skipped
    case .signed(let mode, let signatureKind):
      self = .signed(mode: mode, signatureKind: signatureKind)
    case .failed(let message):
      self = .failed(message: message)
    }
  }
}
