import Foundation
import HarnessMonitorKit

struct TaskBoardGitSettingsDraft: Equatable {
  var enabledWorkflows: Set<TaskBoardOrchestratorWorkflow> = []
  var dryRunDefault = true
  var dispatchStatusFilter: DispatchStatusFilterChoice = .all
  var projectDir = ""
  var owner = ""
  var repo = ""
  var checkoutPath = ""
  var githubInboxRepositoriesText = ""
  var githubInboxLabelFilterText = ""
  var githubInboxRepositoryOwnerInput = ""
  var githubInboxRepositoryNameInput = ""
  var githubInboxLabelInput = ""
  var todoistInboxProjectFilterText = ""
  var defaultBranch = "main"
  var branchPrefix = "c/"
  var mergeMethod: TaskBoardGitHubMergeMethod = .squash
  var managedLabel = "harness:managed"
  var autoMergeLabel = "harness:auto-merge"
  var needsHumanLabel = "harness:needs-human"
  var protectedPathLabel = "harness:protected-path"
  var protectedPathsText = ""
  var requestedReviewersText = ""
  var requestedTeamReviewersText = ""
  var enabledAutomations: Set<TaskBoardGitHubAutomation> = Set(TaskBoardGitHubAutomation.allCases)
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var sshPrivateKey: TaskBoardSecretField = .notConfigured
  var sshPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var signingSSHPrivateKey: TaskBoardSecretField = .notConfigured
  var signingSSHPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKey: TaskBoardSecretField = .notConfigured
  var gpgPrivateKeyPassphrase: TaskBoardSecretField = .notConfigured
  var globalToken: TaskBoardSecretField = .notConfigured
  var todoistToken: TaskBoardSecretField = .notConfigured
  var openRouterToken: TaskBoardSecretField = .notConfigured
  var repositoryOverrides: [TaskBoardRepositoryOverrideDraft] = []
  var policyVersion = ""
  var identityDefaults = TaskBoardGitIdentityDefaults()
  /// Snapshot of the configured secret material loaded with the draft. Save
  /// uses this to re-emit untouched (`.configured`) secrets back to the
  /// daemon so the existing key material is preserved.
  var loadedSecrets = TaskBoardLoadedSecrets()

  init() {}

  init(snapshot: TaskBoardGitSettingsSnapshot) {
    let orchestrator = snapshot.orchestratorSettings
    let project = orchestrator.githubProject
    let runtime = snapshot.runtimeConfig

    enabledWorkflows = Set(orchestrator.enabledWorkflows)
    dryRunDefault = orchestrator.dryRunDefault
    dispatchStatusFilter = DispatchStatusFilterChoice(status: orchestrator.dispatchStatusFilter)
    projectDir = orchestrator.projectDir ?? ""
    owner = project.owner
    repo = project.repo
    checkoutPath = project.checkoutPath
    githubInboxRepositoriesText = orchestrator.githubInbox.repositories.joined(separator: "\n")
    githubInboxLabelFilterText = orchestrator.githubInbox.labelFilter.joined(separator: "\n")
    todoistInboxProjectFilterText = orchestrator.todoistInbox.projectFilter.joined(separator: "\n")
    defaultBranch = project.defaultBranch
    branchPrefix = project.branchPrefix
    mergeMethod = project.mergeMethod
    managedLabel = project.labels.managed
    autoMergeLabel = project.labels.autoMerge
    needsHumanLabel = project.labels.needsHuman
    protectedPathLabel = project.labels.protectedPath
    protectedPathsText = project.protectedPaths.map(\.pattern).joined(separator: "\n")
    requestedReviewersText = project.requestedReviewers.reviewers.joined(separator: "\n")
    requestedTeamReviewersText = project.requestedReviewers.teamReviewers.joined(separator: "\n")
    enabledAutomations = Set(project.enabledAutomations.enabled)
    authorName = runtime.global.authorName ?? ""
    authorEmail = runtime.global.authorEmail ?? ""
    sshKeyPath = runtime.global.sshKeyPath ?? ""
    sshPrivateKey = .secretFromLoaded(runtime.global.sshPrivateKey)
    sshPrivateKeyPassphrase = .secretFromLoaded(runtime.global.sshPrivateKeyPassphrase)
    signingMode = runtime.global.signing.mode
    signingSSHKeyPath = runtime.global.signing.sshKeyPath ?? ""
    signingSSHPrivateKey = .secretFromLoaded(runtime.global.signing.sshPrivateKey)
    signingSSHPrivateKeyPassphrase = .secretFromLoaded(
      runtime.global.signing.sshPrivateKeyPassphrase
    )
    gpgKeyId = runtime.global.signing.gpgKeyId ?? ""
    gpgPrivateKeyPath = runtime.global.signing.gpgPrivateKeyPath ?? ""
    gpgPrivateKey = .secretFromLoaded(runtime.global.signing.gpgPrivateKey)
    gpgPrivateKeyPassphrase = .secretFromLoaded(runtime.global.signing.gpgPrivateKeyPassphrase)
    globalToken = .secretFromLoaded(snapshot.githubCredentials.globalToken)
    todoistToken = .secretFromLoaded(snapshot.todoistCredentials.token)
    openRouterToken = .secretFromLoaded(snapshot.openRouterCredentials.token)
    policyVersion = orchestrator.policyVersion
    identityDefaults = snapshot.identityDefaults
    loadedSecrets = TaskBoardLoadedSecrets(snapshot: snapshot)

    let tokensByRepository = Dictionary(
      snapshot.githubCredentials.repositoryTokens.map { ($0.repository, $0.token) },
      uniquingKeysWith: { existing, _ in
        HarnessMonitorLogger.store.warning(
          """
          SettingsTaskBoardDraft dropped duplicate repository token entry; \
          keeping first token for repository
          """
        )
        return existing
      }
    )
    repositoryOverrides = runtime.repositoryOverrides.map { override in
      TaskBoardRepositoryOverrideDraft(
        repository: override.repository,
        authorName: override.profile.authorName ?? "",
        authorEmail: override.profile.authorEmail ?? "",
        sshKeyPath: override.profile.sshKeyPath ?? "",
        sshPrivateKey: .secretFromLoaded(override.profile.sshPrivateKey),
        sshPrivateKeyPassphrase: .secretFromLoaded(override.profile.sshPrivateKeyPassphrase),
        signingMode: override.profile.signing.mode,
        signingSSHKeyPath: override.profile.signing.sshKeyPath ?? "",
        signingSSHPrivateKey: .secretFromLoaded(override.profile.signing.sshPrivateKey),
        signingSSHPrivateKeyPassphrase: .secretFromLoaded(
          override.profile.signing.sshPrivateKeyPassphrase
        ),
        gpgKeyId: override.profile.signing.gpgKeyId ?? "",
        gpgPrivateKeyPath: override.profile.signing.gpgPrivateKeyPath ?? "",
        gpgPrivateKey: .secretFromLoaded(override.profile.signing.gpgPrivateKey),
        gpgPrivateKeyPassphrase: .secretFromLoaded(
          override.profile.signing.gpgPrivateKeyPassphrase
        ),
        token: .secretFromLoaded(tokensByRepository[override.repository])
      )
    }

    let runtimeRepositories = Set(runtime.repositoryOverrides.map(\.repository))
    let tokenOnlyOverrides = snapshot.githubCredentials.repositoryTokens
      .filter { !runtimeRepositories.contains($0.repository) }
      .map { token in
        TaskBoardRepositoryOverrideDraft(
          repository: token.repository,
          token: .secretFromLoaded(token.token)
        )
      }
    repositoryOverrides.append(contentsOf: tokenOnlyOverrides)
  }

  var snapshot: TaskBoardGitSettingsSnapshot {
    let repositoryOverrides = repositoryOverrides.compactMap { override in
      override.runtimeOverride(loaded: loadedSecrets)
    }
    let repositoryTokens = repositoryOverridesForTokens

    return TaskBoardGitSettingsSnapshot(
      orchestratorSettings: TaskBoardOrchestratorSettings(
        enabledWorkflows: enabledWorkflows.sorted(by: { $0.rawValue < $1.rawValue }),
        dryRunDefault: dryRunDefault,
        dispatchStatusFilter: dispatchStatusFilter.status,
        projectDir: normalized(projectDir),
        githubProject: TaskBoardGitHubProjectConfig(
          owner: owner.trimmingCharacters(in: .whitespacesAndNewlines),
          repo: repo.trimmingCharacters(in: .whitespacesAndNewlines),
          checkoutPath: checkoutPath.trimmingCharacters(in: .whitespacesAndNewlines),
          defaultBranch: normalized(defaultBranch) ?? "main",
          branchPrefix: normalized(branchPrefix) ?? "c/",
          mergeMethod: mergeMethod,
          labels: TaskBoardGitHubAutomationLabels(
            managed: normalized(managedLabel) ?? "harness:managed",
            autoMerge: normalized(autoMergeLabel) ?? "harness:auto-merge",
            needsHuman: normalized(needsHumanLabel) ?? "harness:needs-human",
            protectedPath: normalized(protectedPathLabel) ?? "harness:protected-path"
          ),
          protectedPaths: protectedPaths,
          requestedReviewers: TaskBoardGitHubRequestedReviewers(
            reviewers: normalizedUniqueLines(from: requestedReviewersText),
            teamReviewers: normalizedUniqueLines(from: requestedTeamReviewersText)
          ),
          enabledAutomations: TaskBoardGitHubAutomationToggles(
            enabled: enabledAutomations.sorted(by: { $0.rawValue < $1.rawValue })
          )
        ),
        githubInbox: TaskBoardGitHubInboxConfig(
          repositories: githubInboxRepositoryEntries,
          labelFilter: githubInboxLabelEntries
        ),
        todoistInbox: TaskBoardTodoistInboxConfig(projectFilter: todoistInboxProjects),
        policyVersion: policyVersion
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(
          authorName: normalized(authorName),
          authorEmail: normalized(authorEmail),
          sshKeyPath: normalized(sshKeyPath),
          sshPrivateKey: sshPrivateKey.materialized(loaded: loadedSecrets.globalSSHPrivateKey),
          sshPrivateKeyPassphrase: sshPrivateKeyPassphrase.materialized(
            loaded: loadedSecrets.globalSSHPrivateKeyPassphrase
          ),
          signing: TaskBoardGitSigningConfig(
            mode: signingMode,
            sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
            sshPrivateKey: signingMode == .ssh
              ? signingSSHPrivateKey.materialized(loaded: loadedSecrets.globalSigningSSHPrivateKey)
              : nil,
            sshPrivateKeyPassphrase: signingMode == .ssh
              ? signingSSHPrivateKeyPassphrase.materialized(
                loaded: loadedSecrets.globalSigningSSHPrivateKeyPassphrase
              )
              : nil,
            gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
            gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
            gpgPrivateKey: signingMode == .gpg
              ? gpgPrivateKey.materialized(loaded: loadedSecrets.globalGPGPrivateKey)
              : nil,
            gpgPrivateKeyPassphrase: signingMode == .gpg
              ? gpgPrivateKeyPassphrase.materialized(
                loaded: loadedSecrets.globalGPGPrivateKeyPassphrase
              )
              : nil
          )
        ),
        repositoryOverrides: repositoryOverrides
      ),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(
        globalToken: globalToken.materialized(loaded: loadedSecrets.globalGitHubToken),
        repositoryTokens: repositoryTokens
      ),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(
        token: todoistToken.materialized(loaded: loadedSecrets.todoistToken)
      ),
      openRouterCredentials: TaskBoardOpenRouterCredentialSnapshot(
        token: openRouterToken.materialized(loaded: loadedSecrets.openRouterToken)
      )
    )
  }

  private var protectedPaths: [TaskBoardProtectedPathRule] {
    protectedPathsText
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map(TaskBoardProtectedPathRule.init(pattern:))
  }

  private var repositoryOverridesForTokens: [TaskBoardGitHubRepositoryToken] {
    repositoryOverrides.compactMap { $0.tokenOverride(loaded: loadedSecrets) }
  }

  var githubInboxRepositoryEntries: [String] {
    normalizedRepositories(from: githubInboxRepositoriesText)
  }

  var githubInboxLabelEntries: [String] {
    normalizedFilterEntries(from: githubInboxLabelFilterText)
  }

  var canAddGitHubInboxRepository: Bool {
    normalizedGitHubInboxRepositoryInput != nil
  }

  var canAddGitHubInboxLabel: Bool {
    normalized(githubInboxLabelInput) != nil
  }

  mutating func addGitHubInboxRepositoryInput() {
    guard let repository = normalizedGitHubInboxRepositoryInput else {
      return
    }
    let repositories = appendingUnique(
      repository,
      to: githubInboxRepositoryEntries,
      caseInsensitive: true
    )
    githubInboxRepositoriesText = repositories.joined(separator: "\n")
    githubInboxRepositoryOwnerInput = ""
    githubInboxRepositoryNameInput = ""
  }

  mutating func removeGitHubInboxRepository(_ repository: String) {
    let target = repository.lowercased()
    githubInboxRepositoriesText =
      githubInboxRepositoryEntries
      .filter { $0.lowercased() != target }
      .joined(separator: "\n")
  }

  mutating func addGitHubInboxLabelInput() {
    guard let label = normalized(githubInboxLabelInput) else {
      return
    }
    let labels = appendingUnique(label, to: githubInboxLabelEntries, caseInsensitive: true)
    githubInboxLabelFilterText = labels.joined(separator: "\n")
    githubInboxLabelInput = ""
  }

  mutating func removeGitHubInboxLabel(_ label: String) {
    let target = label.lowercased()
    githubInboxLabelFilterText =
      githubInboxLabelEntries
      .filter { $0.lowercased() != target }
      .joined(separator: "\n")
  }

  private var todoistInboxProjects: [String] {
    normalizedFilterEntries(from: todoistInboxProjectFilterText)
  }

  private func normalizedFilterEntries(from value: String) -> [String] {
    var entries: [String] = []
    var seen: Set<String> = []
    for entry in value.split(whereSeparator: \.isNewline) {
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      if seen.insert(key).inserted {
        entries.append(trimmed)
      }
    }
    return entries
  }

  private func normalizedUniqueLines(from value: String) -> [String] {
    var entries: [String] = []
    var seen: Set<String> = []
    for line in value.split(whereSeparator: \.isNewline) {
      guard let trimmed = normalized(String(line)) else { continue }
      if seen.insert(trimmed).inserted {
        entries.append(trimmed)
      }
    }
    return entries
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var normalizedGitHubInboxRepositoryInput: String? {
    normalizedRepository(
      owner: githubInboxRepositoryOwnerInput,
      repo: githubInboxRepositoryNameInput
    )
  }

  private func normalizedRepositories(from value: String) -> [String] {
    var repositories: [String] = []
    var seen: Set<String> = []
    for entry in value.split(whereSeparator: \.isNewline) {
      guard let repository = normalizedRepositoryEntry(String(entry)) else {
        continue
      }
      let key = repository.lowercased()
      if seen.insert(key).inserted {
        repositories.append(repository)
      }
    }
    return repositories
  }

  private func normalizedRepositoryEntry(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let parts = trimmed.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return trimmed
    }
    let owner = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let repo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repository = normalizedRepository(owner: owner, repo: repo) else {
      return trimmed
    }
    return repository
  }

  private func normalizedRepository(owner: String, repo: String) -> String? {
    guard let owner = normalized(owner), let repo = normalized(repo), !repo.contains("/") else {
      return nil
    }
    return "\(owner.lowercased())/\(repo.lowercased())"
  }

  private func appendingUnique(
    _ value: String,
    to entries: [String],
    caseInsensitive: Bool
  ) -> [String] {
    let key = caseInsensitive ? value.lowercased() : value
    let existingKeys = Set(entries.map { caseInsensitive ? $0.lowercased() : $0 })
    guard !existingKeys.contains(key) else {
      return entries
    }
    return entries + [value]
  }
}
