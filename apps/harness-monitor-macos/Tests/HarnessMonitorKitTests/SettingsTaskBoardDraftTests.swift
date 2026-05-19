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
    draft.todoistToken = .editing(" next-todoist-token ")

    let snapshot = draft.snapshot

    #expect(snapshot.githubCredentials.globalToken == "ghu_global")
    #expect(snapshot.todoistCredentials.token == "next-todoist-token")
    #expect(snapshot.todoistCredentials.syncRequest.token == "next-todoist-token")
  }

  @Test("Blank Todoist token clears secure credential")
  func blankTodoistTokenClearsCredential() {
    var draft = TaskBoardGitSettingsDraft()
    draft.todoistToken = .editing("   ")

    #expect(draft.snapshot.todoistCredentials.token == nil)
    #expect(draft.snapshot.todoistCredentials.isEmpty)
  }

  @Test("Global direct signing key fields round trip through runtime snapshot")
  func globalDirectSigningKeyFieldsRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.signingMode = .gpg
    draft.gpgKeyId = " ABC123 "
    draft.gpgPrivateKeyPath = " /Users/test/.gnupg/private.asc "
    draft.gpgPrivateKey = .editing(
      " -----BEGIN PGP PRIVATE KEY BLOCK-----\n"
        + "secret\n"
        + "-----END PGP PRIVATE KEY BLOCK----- "
    )
    draft.gpgPrivateKeyPassphrase = .editing(" passphrase ")

    let signing = draft.snapshot.runtimeConfig.global.signing

    #expect(signing.mode == .gpg)
    #expect(signing.gpgKeyId == "ABC123")
    #expect(signing.gpgPrivateKeyPath == "/Users/test/.gnupg/private.asc")
    #expect(
      signing.gpgPrivateKey
        == "-----BEGIN PGP PRIVATE KEY BLOCK-----\nsecret\n-----END PGP PRIVATE KEY BLOCK-----"
    )
    #expect(signing.gpgPrivateKeyPassphrase == "passphrase")
  }

  @Test("Global inline SSH material round trips through runtime snapshot")
  func globalInlineSSHMaterialRoundTrips() {
    var draft = TaskBoardGitSettingsDraft()
    draft.sshPrivateKey = .editing(
      " -----BEGIN OPENSSH PRIVATE KEY-----\n"
        + "secret\n"
        + "-----END OPENSSH PRIVATE KEY----- "
    )
    draft.sshPrivateKeyPassphrase = .editing(" identity-passphrase ")
    draft.signingMode = .ssh
    draft.signingSSHPrivateKey = .editing(" signing-secret ")
    draft.signingSSHPrivateKeyPassphrase = .editing(" signing-passphrase ")

    let profile = draft.snapshot.runtimeConfig.global

    #expect(
      profile.sshPrivateKey
        == "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----"
    )
    #expect(profile.sshPrivateKeyPassphrase == "identity-passphrase")
    #expect(profile.signing.sshPrivateKey == "signing-secret")
    #expect(profile.signing.sshPrivateKeyPassphrase == "signing-passphrase")
    #expect(profile.signing.sshKeyPath == nil)
  }

  @Test("Repository direct signing key fields round trip through override snapshot")
  func repositoryDirectSigningKeyFieldsRoundTrip() throws {
    var draft = TaskBoardGitSettingsDraft()
    draft.repositoryOverrides = [
      TaskBoardRepositoryOverrideDraft(
        repository: " EXAMPLE/HARNESS ",
        sshPrivateKey: .editing(" repo-identity-secret "),
        sshPrivateKeyPassphrase: .editing(" repo-identity-passphrase "),
        signingMode: .gpg,
        gpgKeyId: " DEF456 ",
        gpgPrivateKeyPath: " /Users/test/.gnupg/repo.asc ",
        gpgPrivateKey: .editing(" repo-gpg-secret "),
        gpgPrivateKeyPassphrase: .editing(" repo-passphrase ")
      )
    ]

    let override = try #require(draft.snapshot.runtimeConfig.repositoryOverrides.first)
    let signing = override.profile.signing

    #expect(override.repository == "example/harness")
    #expect(override.profile.sshPrivateKey == "repo-identity-secret")
    #expect(override.profile.sshPrivateKeyPassphrase == "repo-identity-passphrase")
    #expect(signing.mode == .gpg)
    #expect(signing.gpgKeyId == "DEF456")
    #expect(signing.gpgPrivateKeyPath == "/Users/test/.gnupg/repo.asc")
    #expect(signing.gpgPrivateKey == "repo-gpg-secret")
    #expect(signing.gpgPrivateKeyPassphrase == "repo-passphrase")
  }

  @Test("GitHub requested reviewers round trip preserves first-seen order")
  func githubRequestedReviewersRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.requestedReviewersText = " bob \n alice \n bob "
    draft.requestedTeamReviewersText = " platform \n security \n platform "

    let reviewers = draft.snapshot.orchestratorSettings.githubProject.requestedReviewers

    #expect(reviewers.reviewers == ["bob", "alice"])
    #expect(reviewers.teamReviewers == ["platform", "security"])
  }

  @Test("GitHub inbox repositories round trip through orchestrator snapshot")
  func githubInboxRepositoriesRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxRepositoriesText = " EXAMPLE/HARNESS \n example/aff \n EXAMPLE/HARNESS "

    let repositories = draft.snapshot.orchestratorSettings.githubInbox.repositories

    #expect(repositories == ["example/harness", "example/aff"])
  }

  @Test("GitHub inbox repository editor adds, dedupes, and removes entries")
  func githubInboxRepositoryEditorMutations() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxRepositoryInput = " EXAMPLE/HARNESS "

    #expect(draft.canAddGitHubInboxRepository)
    draft.addGitHubInboxRepositoryInput()
    draft.githubInboxRepositoryInput = "example/harness"
    draft.addGitHubInboxRepositoryInput()

    #expect(draft.githubInboxRepositoryEntries == ["example/harness"])

    draft.githubInboxRepositoryInput = "missing-repo"
    #expect(!draft.canAddGitHubInboxRepository)

    draft.removeGitHubInboxRepository("EXAMPLE/HARNESS")
    #expect(draft.githubInboxRepositoryEntries.isEmpty)
  }

  @Test("GitHub inbox label filter trims, dedupes case-insensitively, preserves first casing")
  func githubInboxLabelFilterRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxLabelFilterText = " Bug \n triage \n  bug  \n needs-design "

    let labels = draft.snapshot.orchestratorSettings.githubInbox.labelFilter

    #expect(labels == ["Bug", "triage", "needs-design"])
  }

  @Test("GitHub inbox label editor leaves all labels when empty")
  func githubInboxLabelEditorMutations() {
    var draft = TaskBoardGitSettingsDraft()

    #expect(draft.githubInboxLabelEntries.isEmpty)
    #expect(draft.snapshot.orchestratorSettings.githubInbox.labelFilter.isEmpty)

    draft.githubInboxLabelInput = " Bug "
    draft.addGitHubInboxLabelInput()
    draft.githubInboxLabelInput = "bug"
    draft.addGitHubInboxLabelInput()

    #expect(draft.githubInboxLabelEntries == ["Bug"])

    draft.removeGitHubInboxLabel("BUG")
    #expect(draft.githubInboxLabelEntries.isEmpty)
    #expect(draft.snapshot.orchestratorSettings.githubInbox.labelFilter.isEmpty)
  }

  @Test("Todoist inbox project filter trims and dedupes through orchestrator snapshot")
  func todoistInboxProjectFilterRoundTrip() {
    var draft = TaskBoardGitSettingsDraft()
    draft.todoistInboxProjectFilterText = " 1234567890 \n 1234567890 \n 9876543210 \n "

    let projects = draft.snapshot.orchestratorSettings.todoistInbox.projectFilter

    #expect(projects == ["1234567890", "9876543210"])
  }
}
