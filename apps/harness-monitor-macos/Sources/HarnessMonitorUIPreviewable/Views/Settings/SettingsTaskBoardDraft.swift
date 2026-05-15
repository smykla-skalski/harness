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
  var sshPrivateKey = ""
  var sshPrivateKeyPassphrase = ""
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var signingSSHPrivateKey = ""
  var signingSSHPrivateKeyPassphrase = ""
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKey = ""
  var gpgPrivateKeyPassphrase = ""
  var globalToken = ""
  var todoistToken = ""
  var repositoryOverrides: [TaskBoardRepositoryOverrideDraft] = []
  var policyVersion = ""

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
    sshPrivateKey = runtime.global.sshPrivateKey ?? ""
    sshPrivateKeyPassphrase = runtime.global.sshPrivateKeyPassphrase ?? ""
    signingMode = runtime.global.signing.mode
    signingSSHKeyPath = runtime.global.signing.sshKeyPath ?? ""
    signingSSHPrivateKey = runtime.global.signing.sshPrivateKey ?? ""
    signingSSHPrivateKeyPassphrase = runtime.global.signing.sshPrivateKeyPassphrase ?? ""
    gpgKeyId = runtime.global.signing.gpgKeyId ?? ""
    gpgPrivateKeyPath = runtime.global.signing.gpgPrivateKeyPath ?? ""
    gpgPrivateKey = runtime.global.signing.gpgPrivateKey ?? ""
    gpgPrivateKeyPassphrase = runtime.global.signing.gpgPrivateKeyPassphrase ?? ""
    globalToken = snapshot.githubCredentials.globalToken ?? ""
    todoistToken = snapshot.todoistCredentials.token ?? ""
    policyVersion = orchestrator.policyVersion

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
        sshPrivateKey: override.profile.sshPrivateKey ?? "",
        sshPrivateKeyPassphrase: override.profile.sshPrivateKeyPassphrase ?? "",
        signingMode: override.profile.signing.mode,
        signingSSHKeyPath: override.profile.signing.sshKeyPath ?? "",
        signingSSHPrivateKey: override.profile.signing.sshPrivateKey ?? "",
        signingSSHPrivateKeyPassphrase: override.profile.signing.sshPrivateKeyPassphrase ?? "",
        gpgKeyId: override.profile.signing.gpgKeyId ?? "",
        gpgPrivateKeyPath: override.profile.signing.gpgPrivateKeyPath ?? "",
        gpgPrivateKey: override.profile.signing.gpgPrivateKey ?? "",
        gpgPrivateKeyPassphrase: override.profile.signing.gpgPrivateKeyPassphrase ?? "",
        token: tokensByRepository[override.repository] ?? ""
      )
    }

    let runtimeRepositories = Set(runtime.repositoryOverrides.map(\.repository))
    let tokenOnlyOverrides = snapshot.githubCredentials.repositoryTokens
      .filter { !runtimeRepositories.contains($0.repository) }
      .map { token in
        TaskBoardRepositoryOverrideDraft(
          repository: token.repository,
          token: token.token
        )
      }
    repositoryOverrides.append(contentsOf: tokenOnlyOverrides)
  }

  var snapshot: TaskBoardGitSettingsSnapshot {
    let repositoryOverrides = repositoryOverrides.compactMap(\.runtimeOverride)
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
          repositories: githubInboxRepositories,
          labelFilter: githubInboxLabels
        ),
        todoistInbox: TaskBoardTodoistInboxConfig(projectFilter: todoistInboxProjects),
        policyVersion: policyVersion
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(
          authorName: normalized(authorName),
          authorEmail: normalized(authorEmail),
          sshKeyPath: normalized(sshKeyPath),
          sshPrivateKey: normalized(sshPrivateKey),
          sshPrivateKeyPassphrase: normalized(sshPrivateKeyPassphrase),
          signing: TaskBoardGitSigningConfig(
            mode: signingMode,
            sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
            sshPrivateKey: signingMode == .ssh ? normalized(signingSSHPrivateKey) : nil,
            sshPrivateKeyPassphrase: signingMode == .ssh
              ? normalized(signingSSHPrivateKeyPassphrase)
              : nil,
            gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
            gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
            gpgPrivateKey: signingMode == .gpg ? normalized(gpgPrivateKey) : nil,
            gpgPrivateKeyPassphrase: signingMode == .gpg
              ? normalized(gpgPrivateKeyPassphrase)
              : nil
          )
        ),
        repositoryOverrides: repositoryOverrides
      ),
      githubCredentials: TaskBoardGitHubCredentialSnapshot(
        globalToken: normalized(globalToken),
        repositoryTokens: repositoryTokens
      ),
      todoistCredentials: TaskBoardTodoistCredentialSnapshot(
        token: normalized(todoistToken)
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
    repositoryOverrides.compactMap(\.tokenOverride)
  }

  private var githubInboxRepositories: [String] {
    normalizedRepositories(from: githubInboxRepositoriesText)
  }

  private var githubInboxLabels: [String] {
    normalizedFilterEntries(from: githubInboxLabelFilterText)
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
    Array(
      Set(
        value
          .split(whereSeparator: \.isNewline)
          .compactMap { normalized(String($0)) }
      )
    )
    .sorted()
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
    guard !owner.isEmpty, !repo.isEmpty, !repo.contains("/") else {
      return trimmed
    }
    return "\(owner.lowercased())/\(repo.lowercased())"
  }
}

struct TaskBoardRepositoryOverrideDraft: Identifiable, Equatable {
  let id: UUID
  var repository = ""
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var sshPrivateKey = ""
  var sshPrivateKeyPassphrase = ""
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var signingSSHPrivateKey = ""
  var signingSSHPrivateKeyPassphrase = ""
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKey = ""
  var gpgPrivateKeyPassphrase = ""
  var token = ""

  init(
    id: UUID = UUID(),
    repository: String = "",
    authorName: String = "",
    authorEmail: String = "",
    sshKeyPath: String = "",
    sshPrivateKey: String = "",
    sshPrivateKeyPassphrase: String = "",
    signingMode: TaskBoardGitSigningMode = .none,
    signingSSHKeyPath: String = "",
    signingSSHPrivateKey: String = "",
    signingSSHPrivateKeyPassphrase: String = "",
    gpgKeyId: String = "",
    gpgPrivateKeyPath: String = "",
    gpgPrivateKey: String = "",
    gpgPrivateKeyPassphrase: String = "",
    token: String = ""
  ) {
    self.id = id
    self.repository = repository
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.sshPrivateKey = sshPrivateKey
    self.sshPrivateKeyPassphrase = sshPrivateKeyPassphrase
    self.signingMode = signingMode
    self.signingSSHKeyPath = signingSSHKeyPath
    self.signingSSHPrivateKey = signingSSHPrivateKey
    self.signingSSHPrivateKeyPassphrase = signingSSHPrivateKeyPassphrase
    self.gpgKeyId = gpgKeyId
    self.gpgPrivateKeyPath = gpgPrivateKeyPath
    self.gpgPrivateKey = gpgPrivateKey
    self.gpgPrivateKeyPassphrase = gpgPrivateKeyPassphrase
    self.token = token
  }

  var runtimeOverride: TaskBoardGitRepositoryOverride? {
    guard let repository = normalized(repository), hasRuntimeOverride else {
      return nil
    }
    return TaskBoardGitRepositoryOverride(
      repository: repository.lowercased(),
      profile: TaskBoardGitRuntimeProfile(
        authorName: normalized(authorName),
        authorEmail: normalized(authorEmail),
        sshKeyPath: normalized(sshKeyPath),
        sshPrivateKey: normalized(sshPrivateKey),
        sshPrivateKeyPassphrase: normalized(sshPrivateKeyPassphrase),
        signing: TaskBoardGitSigningConfig(
          mode: signingMode,
          sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
          sshPrivateKey: signingMode == .ssh ? normalized(signingSSHPrivateKey) : nil,
          sshPrivateKeyPassphrase: signingMode == .ssh
            ? normalized(signingSSHPrivateKeyPassphrase)
            : nil,
          gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
          gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
          gpgPrivateKey: signingMode == .gpg ? normalized(gpgPrivateKey) : nil,
          gpgPrivateKeyPassphrase: signingMode == .gpg
            ? normalized(gpgPrivateKeyPassphrase)
            : nil
        )
      )
    )
  }

  var tokenOverride: TaskBoardGitHubRepositoryToken? {
    guard let repository = normalized(repository)?.lowercased(), let token = normalized(token)
    else {
      return nil
    }
    return TaskBoardGitHubRepositoryToken(repository: repository, token: token)
  }

  private var hasRuntimeOverride: Bool {
    normalized(authorName) != nil
      || normalized(authorEmail) != nil
      || normalized(sshKeyPath) != nil
      || normalized(sshPrivateKey) != nil
      || normalized(sshPrivateKeyPassphrase) != nil
      || (signingMode == .ssh && normalized(signingSSHKeyPath) != nil)
      || (signingMode == .ssh && normalized(signingSSHPrivateKey) != nil)
      || (signingMode == .ssh && normalized(signingSSHPrivateKeyPassphrase) != nil)
      || (signingMode == .gpg && normalized(gpgKeyId) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKeyPath) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKey) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKeyPassphrase) != nil)
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
