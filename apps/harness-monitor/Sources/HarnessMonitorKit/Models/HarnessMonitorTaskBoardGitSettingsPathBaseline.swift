public struct TaskBoardGitSettingsPathBaseline: Equatable, Sendable {
  struct RuntimeProfile: Equatable, Sendable {
    let sshKeyPath: String?
    let signingSSHKeyPath: String?
    let gpgPrivateKeyPath: String?

    init(_ profile: TaskBoardGitRuntimeProfile) {
      sshKeyPath = profile.sshKeyPath
      signingSSHKeyPath = profile.signing.sshKeyPath
      gpgPrivateKeyPath = profile.signing.gpgPrivateKeyPath
    }
  }

  struct Repository: Equatable, Sendable {
    let slug: String
    let profile: RuntimeProfile
  }

  let projectDir: String?
  let global: RuntimeProfile
  let repositories: [Repository]

  public init(snapshot: TaskBoardGitSettingsSnapshot) {
    projectDir = snapshot.orchestratorSettings.projectDir
    global = RuntimeProfile(snapshot.runtimeConfig.global)
    repositories = snapshot.runtimeConfig.repositoryOverrides.map { override in
      Repository(
        slug: override.repository.lowercased(),
        profile: RuntimeProfile(override.profile)
      )
    }
  }

  func profile(for repository: String) -> RuntimeProfile? {
    let slug = repository.lowercased()
    return repositories.first { $0.slug == slug }?.profile
  }
}
