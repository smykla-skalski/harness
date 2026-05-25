import Foundation
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

  @Test("GitHub inbox repositories reject malformed repository paths")
  func githubInboxRepositoriesRejectMalformedRepositoryPaths() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxRepositoriesText = """
       EXAMPLE/HARNESS/EXTRA
       example/valid
       example/
       /harness
      """

    #expect(draft.githubInboxRepositoryEntries == ["example/valid"])
    #expect(draft.snapshot.orchestratorSettings.githubInbox.repositories == ["example/valid"])
  }

  @Test("GitHub inbox repository editor adds, dedupes, and removes entries")
  func githubInboxRepositoryEditorMutations() {
    var draft = TaskBoardGitSettingsDraft()
    draft.githubInboxRepositoryOwnerInput = " EXAMPLE "
    draft.githubInboxRepositoryNameInput = " HARNESS "

    #expect(draft.canAddGitHubInboxRepository)
    draft.addGitHubInboxRepositoryInput()
    draft.githubInboxRepositoryOwnerInput = "example"
    draft.githubInboxRepositoryNameInput = "harness"
    draft.addGitHubInboxRepositoryInput()

    #expect(draft.githubInboxRepositoryEntries == ["example/harness"])

    draft.githubInboxRepositoryOwnerInput = "example"
    draft.githubInboxRepositoryNameInput = "nested/repo"
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

@Suite("Settings repositories catalog error presentation")
struct SettingsRepositoriesCatalogErrorPresentationTests {
  @Test("Missing GitHub token points users to Secrets")
  func missingGitHubTokenPointsUsersToSecrets() {
    let presentation = SettingsRepositoriesCatalogErrorPresentation(
      error: HarnessMonitorAPIError.server(
        code: 400,
        message: "reviews requires a GitHub token. Configure one in Settings > Secrets."
      ),
      organization: "smykla-skalski"
    )

    #expect(presentation.title == "GitHub token required")
    #expect(
      presentation.message
        == "Add a GitHub token in Settings > Secrets, then load repositories again."
    )
    #expect(presentation.action == .openSecrets)
  }

  @Test("Fine-grained token lifetime errors surface friendly recovery copy")
  func fineGrainedTokenLifetimeErrorsSurfaceFriendlyRecoveryCopy() throws {
    let message =
      "reviews github request failed: GraphQL Error: The 'smykla-skalski' organization "
      + "forbids access via a fine-grained personal access tokens if the token's lifetime is "
      + "greater than 366 days. Please adjust your token's lifetime at the following URL: "
      + "https://github.com/settings/personal-access-tokens/14799622 (path: [Path(\"organization\")])"
    let presentation = SettingsRepositoriesCatalogErrorPresentation(
      error: HarnessMonitorAPIError.server(code: 400, message: message),
      organization: "smykla-skalski"
    )

    #expect(presentation.title == "GitHub token needs attention")
    #expect(
      presentation.message
        == "GitHub blocked access to smykla-skalski because the current fine-grained token "
        + "exceeds the organization's lifetime policy. Update the token, then load "
        + "repositories again."
    )

    guard case .openURL(let url)? = presentation.action else {
      Issue.record("expected token settings recovery action")
      return
    }
    #expect(url == URL(string: "https://github.com/settings/personal-access-tokens/14799622"))
  }
}

@Suite("Settings repositories performance source contracts")
struct SettingsRepositoriesPerformanceSourceTests {
  @Test("Repositories settings keeps large lists lazy and indexed")
  func repositoriesSettingsKeepsLargeListsLazyAndIndexed() throws {
    let source = try settingsSourceFiles([
      "SettingsRepositoriesSection.swift",
      "SettingsRepositoriesSection+Catalog.swift",
      "SettingsRepositoriesSection+Persistence.swift",
      "SettingsRepositoriesSection+Table.swift",
      "SettingsSharedRepositoriesDraft.swift",
    ])

    #expect(source.contains("SettingsRepositoriesCatalogLoader.load("))
    #expect(source.contains("Task.detached(priority: .userInitiated)"))
    #expect(source.contains("LazyVStack(spacing: 0)"))
    #expect(source.contains("ForEach(draft.rows) { row in"))
    #expect(source.contains("ForEach(repositories, id: \\.self) { repository in"))
    #expect(!source.contains("if index > 0"))
    #expect(!source.contains("Array(draft.rows.enumerated())"))
    #expect(!source.contains("Array(repositories.enumerated())"))
    #expect(!source.contains("rows.firstIndex(where:"))
    #expect(!source.contains("rowIndexesByID()"))
    #expect(source.contains("private var rowIndexes: [String: Int] = [:]"))
    #expect(source.contains("func index(for rowID: String) -> Int?"))
  }

  @Test("Supervisor panes are retained without hidden scroll or MCP work")
  func supervisorPanesAreRetainedWithoutHiddenScrollOrMCPWork() throws {
    let source = try settingsSourceFile("Supervisor/SettingsSupervisorSection.swift")

    #expect(source.contains("SupervisorRetainedPaneLayout(selectedPane: selectedPane)"))
    #expect(source.contains("SupervisorRetainedPaneHost("))
    #expect(source.contains(".equatable()"))
    #expect(source.contains("visit(newValue)"))
    #expect(source.contains("guard !visitedPanes.contains(pane)"))
    #expect(source.contains("selectedSubview(in: subviews)?.sizeThatFits(proposal)"))
    #expect(
      source.contains(
        ".environment(\\.settingsScrollRestorationSection, isSelected ? settingsSection : nil)"
      )
    )
    #expect(source.contains(".harnessMCPElementTrackingEnabled(isSelected)"))
    #expect(!source.contains("switch selectedPane"))
  }

  @Test("Top-level retained settings sections disable hidden scroll and MCP hooks")
  func topLevelRetainedSettingsSectionsDisableHiddenScrollAndMCPHooks() throws {
    let source = try settingsSourceFile("SettingsView.swift")

    #expect(source.contains("SettingsRetainedSectionHost("))
    #expect(source.contains(".equatable()"))
    #expect(source.contains("visit(newValue)"))
    #expect(source.contains("guard !visitedSections.contains(section)"))
    #expect(
      source.contains(
        ".environment(\\.settingsScrollRestorationSection, isSelected ? section : nil)"
      )
    )
    #expect(source.contains(".harnessMCPElementTrackingEnabled(isSelected)"))
  }

  private func settingsSourceFile(_ relativePath: String) throws -> String {
    try settingsSourceFiles([relativePath])
  }

  private func settingsSourceFiles(_ relativePaths: [String]) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let settingsRoot =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Settings"
      )
    return
      try relativePaths
      .map { relativePath in
        try String(
          contentsOf: settingsRoot.appendingPathComponent(relativePath),
          encoding: .utf8
        )
      }
      .joined(separator: "\n")
  }
}
