import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Settings task-board draft")
struct SettingsTaskBoardDraftTests {
  @Test("Todoist token round trips through secure credentials snapshot")
  func todoistTokenRoundTripsThroughSnapshot() {
    let source = TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(policyVersion: "task-board-policy-v1"),
      runtimeConfig: TaskBoardGitRuntimeConfig(),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(globalToken: "ghu_global"),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(token: "todoist-token")
    )

    var draft = TaskBoardGitSettingsDraft(snapshot: source)
    draft.todoistToken = " next-todoist-token "

    let snapshot = draft.snapshot

    #expect(snapshot.githubCredentials.globalToken == "ghu_global")
    #expect(snapshot.todoistCredentials.token == "next-todoist-token")
    #expect(snapshot.todoistCredentials.syncRequest.token == "next-todoist-token")
  }

  @Test("Blank Todoist token clears secure credential")
  func blankTodoistTokenClearsCredential() {
    var draft = TaskBoardGitSettingsDraft()
    draft.todoistToken = "   "

    #expect(draft.snapshot.todoistCredentials.token == nil)
    #expect(draft.snapshot.todoistCredentials.isEmpty)
  }

  @Test("Global direct signing key fields round trip through runtime snapshot")
  func globalDirectSigningKeyFieldsRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.signingMode = .gpg
    draft.gpgKeyId = " ABC123 "
    draft.gpgPrivateKeyPath = " /Users/test/.gnupg/private.asc "
    draft.gpgPrivateKeyPassphrase = " passphrase "

    let signing = draft.snapshot.runtimeConfig.global.signing

    #expect(signing.mode == .gpg)
    #expect(signing.gpgKeyId == "ABC123")
    #expect(signing.gpgPrivateKeyPath == "/Users/test/.gnupg/private.asc")
    #expect(signing.gpgPrivateKeyPassphrase == "passphrase")
  }

  @Test("Repository direct signing key fields round trip through override snapshot")
  func repositoryDirectSigningKeyFieldsRoundTrip() throws {
    var draft = TaskBoardGitSettingsDraft()
    draft.repositoryOverrides = [
      TaskBoardRepositoryOverrideDraft(
        repository: " EXAMPLE/HARNESS ",
        signingMode: .gpg,
        gpgKeyId: " DEF456 ",
        gpgPrivateKeyPath: " /Users/test/.gnupg/repo.asc ",
        gpgPrivateKeyPassphrase: " repo-passphrase "
      )
    ]

    let override = try #require(draft.snapshot.runtimeConfig.repositoryOverrides.first)
    let signing = override.profile.signing

    #expect(override.repository == "example/harness")
    #expect(signing.mode == .gpg)
    #expect(signing.gpgKeyId == "DEF456")
    #expect(signing.gpgPrivateKeyPath == "/Users/test/.gnupg/repo.asc")
    #expect(signing.gpgPrivateKeyPassphrase == "repo-passphrase")
  }

  @Test("GitHub inbox repositories round trip through orchestrator snapshot")
  func githubInboxRepositoriesRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxRepositoriesText = " EXAMPLE/HARNESS \n example/aff \n EXAMPLE/HARNESS "

    let repositories = draft.snapshot.orchestratorSettings.githubInbox.repositories

    #expect(repositories == ["example/harness", "example/aff"])
  }
}
