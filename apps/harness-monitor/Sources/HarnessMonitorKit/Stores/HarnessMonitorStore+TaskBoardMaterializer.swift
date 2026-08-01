import Foundation

extension HarnessMonitorStore {
  func materializeTaskBoardGitSettings(
    _ snapshot: TaskBoardGitSettingsSnapshot,
    preservingPathsFrom baseline: TaskBoardGitSettingsPathBaseline? = nil
  ) async throws -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: try await materializeTaskBoardOrchestratorSettings(
        snapshot.orchestratorSettings,
        preservingProjectDir: baseline?.projectDir
      ),
      runtimeConfig: try await materializeTaskBoardGitRuntimeConfig(
        snapshot.runtimeConfig,
        preservingPathsFrom: baseline
      ),
      githubCredentials: snapshot.githubCredentials,
      openRouterCredentials: snapshot.openRouterCredentials
    )
  }

  private func materializeTaskBoardOrchestratorSettings(
    _ settings: TaskBoardOrchestratorSettings,
    preservingProjectDir projectDirBaseline: String?
  ) async throws -> TaskBoardOrchestratorSettings {
    return TaskBoardOrchestratorSettings(
      stepMode: settings.stepMode,
      enabledWorkflows: settings.enabledWorkflows,
      dryRunDefault: settings.dryRunDefault,
      dispatchStatusFilter: settings.dispatchStatusFilter,
      projectDir: try await materializeTaskBoardPath(
        settings.projectDir,
        preserving: projectDirBaseline,
        kind: .taskBoardDirectory,
        isDirectory: true
      ),
      // Passes straight through: the checkout path was the one member that
      // named a sandbox location needing a bookmark resolved, and it is gone.
      githubProject: settings.githubProject,
      githubInbox: settings.githubInbox,
      scheduling: settings.scheduling,
      retry: settings.retry,
      reviewers: settings.reviewers,
      repositories: settings.repositories,
      policyVersion: settings.policyVersion
    )
  }

  private func materializeTaskBoardGitRuntimeConfig(
    _ config: TaskBoardGitRuntimeConfig,
    preservingPathsFrom baseline: TaskBoardGitSettingsPathBaseline?
  ) async throws -> TaskBoardGitRuntimeConfig {
    var repositoryOverrides: [TaskBoardGitRepositoryOverride] = []
    repositoryOverrides.reserveCapacity(config.repositoryOverrides.count)
    for override in config.repositoryOverrides {
      repositoryOverrides.append(
        TaskBoardGitRepositoryOverride(
          repository: override.repository,
          profile: try await materializeTaskBoardGitRuntimeProfile(
            override.profile,
            preservingPathsFrom: baseline?.profile(for: override.repository)
          )
        )
      )
    }
    return TaskBoardGitRuntimeConfig(
      global: try await materializeTaskBoardGitRuntimeProfile(
        config.global,
        preservingPathsFrom: baseline?.global
      ),
      repositoryOverrides: repositoryOverrides
    )
  }

  private func materializeTaskBoardGitRuntimeProfile(
    _ profile: TaskBoardGitRuntimeProfile,
    preservingPathsFrom baseline: TaskBoardGitSettingsPathBaseline.RuntimeProfile?
  ) async throws -> TaskBoardGitRuntimeProfile {
    let signing = profile.signing
    let signingSSHKeyPath: String? =
      if signing.mode == .ssh {
        try await materializeTaskBoardPath(
          signing.sshKeyPath,
          preserving: baseline?.signingSSHKeyPath,
          kind: .taskBoardKeyFile,
          isDirectory: false
        )
      } else {
        nil
      }
    let signingGPGPrivateKeyPath: String? =
      if signing.mode == .gpg {
        try await materializeTaskBoardPath(
          signing.gpgPrivateKeyPath,
          preserving: baseline?.gpgPrivateKeyPath,
          kind: .taskBoardKeyFile,
          isDirectory: false
        )
      } else {
        nil
      }

    return TaskBoardGitRuntimeProfile(
      authorName: profile.authorName,
      authorEmail: profile.authorEmail,
      sshKeyPath: try await materializeTaskBoardPath(
        profile.sshKeyPath,
        preserving: baseline?.sshKeyPath,
        kind: .taskBoardKeyFile,
        isDirectory: false
      ),
      sshPrivateKey: profile.sshPrivateKey,
      sshPrivateKeyPassphrase: profile.sshPrivateKeyPassphrase,
      signing: TaskBoardGitSigningConfig(
        mode: signing.mode,
        sshKeyPath: signingSSHKeyPath,
        sshPrivateKey: signing.mode == .ssh ? signing.sshPrivateKey : nil,
        sshPrivateKeyPassphrase: signing.mode == .ssh ? signing.sshPrivateKeyPassphrase : nil,
        gpgKeyId: signing.gpgKeyId,
        gpgPrivateKeyPath: signingGPGPrivateKeyPath,
        gpgPrivateKey: signing.mode == .gpg ? signing.gpgPrivateKey : nil,
        gpgPrivateKeyPassphrase: signing.mode == .gpg ? signing.gpgPrivateKeyPassphrase : nil
      )
    )
  }

  private func materializeTaskBoardPath(
    _ rawPath: String?,
    preserving baselinePath: String?,
    kind: BookmarkStore.Record.Kind,
    isDirectory: Bool
  ) async throws -> String? {
    guard let rawPath else { return nil }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    if baselinePath?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
      return trimmed
    }
    return try await authorizeTaskBoardPath(
      URL(fileURLWithPath: trimmed, isDirectory: isDirectory),
      kind: kind
    )
  }
}
