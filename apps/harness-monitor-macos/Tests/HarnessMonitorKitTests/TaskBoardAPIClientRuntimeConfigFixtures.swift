@testable import HarnessMonitorKit

func taskBoardRuntimeConfigUpdateRequest() -> TaskBoardGitRuntimeConfig {
  TaskBoardGitRuntimeConfig(
    global: TaskBoardGitRuntimeProfile(
      authorName: "Harness Bot",
      authorEmail: "bot@example.com",
      sshKeyPath: "/Users/test/.ssh/id_ed25519",
      signing: TaskBoardGitSigningConfig(
        mode: .ssh,
        sshKeyPath: "/Users/test/.ssh/id_signing"
      )
    ),
    repositoryOverrides: [
      TaskBoardGitRepositoryOverride(
        repository: "kong/harness",
        profile: TaskBoardGitRuntimeProfile(
          authorName: "Repo Bot",
          authorEmail: "repo@example.com",
          sshKeyPath: "/Users/test/.ssh/id_repo",
          signing: TaskBoardGitSigningConfig(mode: .gpg, gpgKeyId: "ABC123")
        )
      )
    ]
  )
}
