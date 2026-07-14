import Foundation

extension HarnessMonitorStore {
  func materializeTaskBoardGitSettings(
    _ snapshot: TaskBoardGitSettingsSnapshot
  ) async throws -> TaskBoardGitSettingsSnapshot {
    TaskBoardGitSettingsSnapshot(
      orchestratorSettings: try await materializeTaskBoardOrchestratorSettings(
        snapshot.orchestratorSettings
      ),
      runtimeConfig: try await materializeTaskBoardGitRuntimeConfig(snapshot.runtimeConfig),
      githubCredentials: snapshot.githubCredentials,
      todoistCredentials: snapshot.todoistCredentials,
      openRouterCredentials: snapshot.openRouterCredentials
    )
  }

  private func materializeTaskBoardOrchestratorSettings(
    _ settings: TaskBoardOrchestratorSettings
  ) async throws -> TaskBoardOrchestratorSettings {
    let githubProject = settings.githubProject
    return TaskBoardOrchestratorSettings(
      stepMode: settings.stepMode,
      enabledWorkflows: settings.enabledWorkflows,
      dryRunDefault: settings.dryRunDefault,
      dispatchStatusFilter: settings.dispatchStatusFilter,
      projectDir: try await materializeTaskBoardPath(
        settings.projectDir,
        kind: .taskBoardDirectory,
        isDirectory: true
      ),
      githubProject: TaskBoardGitHubProjectConfig(
        owner: githubProject.owner,
        repo: githubProject.repo,
        checkoutPath: try await materializeTaskBoardPath(
          githubProject.checkoutPath,
          kind: .taskBoardDirectory,
          isDirectory: true
        ) ?? "",
        defaultBranch: githubProject.defaultBranch,
        branchPrefix: githubProject.branchPrefix,
        mergeMethod: githubProject.mergeMethod,
        labels: githubProject.labels,
        protectedPaths: githubProject.protectedPaths,
        requestedReviewers: githubProject.requestedReviewers,
        enabledAutomations: githubProject.enabledAutomations
      ),
      githubInbox: settings.githubInbox,
      todoistInbox: settings.todoistInbox,
      policyVersion: settings.policyVersion
    )
  }

  private func materializeTaskBoardGitRuntimeConfig(
    _ config: TaskBoardGitRuntimeConfig
  ) async throws -> TaskBoardGitRuntimeConfig {
    var repositoryOverrides: [TaskBoardGitRepositoryOverride] = []
    repositoryOverrides.reserveCapacity(config.repositoryOverrides.count)
    for override in config.repositoryOverrides {
      repositoryOverrides.append(
        TaskBoardGitRepositoryOverride(
          repository: override.repository,
          profile: try await materializeTaskBoardGitRuntimeProfile(override.profile)
        )
      )
    }
    return TaskBoardGitRuntimeConfig(
      global: try await materializeTaskBoardGitRuntimeProfile(config.global),
      repositoryOverrides: repositoryOverrides
    )
  }

  private func materializeTaskBoardGitRuntimeProfile(
    _ profile: TaskBoardGitRuntimeProfile
  ) async throws -> TaskBoardGitRuntimeProfile {
    let signing = profile.signing
    let signingSSHKeyPath: String? =
      if signing.mode == .ssh {
        try await materializeTaskBoardPath(
          signing.sshKeyPath,
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
    kind: BookmarkStore.Record.Kind,
    isDirectory: Bool
  ) async throws -> String? {
    guard let rawPath else { return nil }
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    return try await authorizeTaskBoardPath(
      URL(fileURLWithPath: trimmed, isDirectory: isDirectory),
      kind: kind
    )
  }
}
