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
  var defaultBranch = "main"
  var branchPrefix = "c/"
  var mergeMethod: TaskBoardGitHubMergeMethod = .squash
  var managedLabel = "harness:managed"
  var autoMergeLabel = "harness:auto-merge"
  var needsHumanLabel = "harness:needs-human"
  var protectedPathLabel = "harness:protected-path"
  var protectedPathsText = ""
  var enabledAutomations: Set<TaskBoardGitHubAutomation> = Set(TaskBoardGitHubAutomation.allCases)
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKeyPassphrase = ""
  var globalToken = ""
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
    defaultBranch = project.defaultBranch
    branchPrefix = project.branchPrefix
    mergeMethod = project.mergeMethod
    managedLabel = project.labels.managed
    autoMergeLabel = project.labels.autoMerge
    needsHumanLabel = project.labels.needsHuman
    protectedPathLabel = project.labels.protectedPath
    protectedPathsText = project.protectedPaths.map(\.pattern).joined(separator: "\n")
    enabledAutomations = Set(project.enabledAutomations.enabled)
    authorName = runtime.global.authorName ?? ""
    authorEmail = runtime.global.authorEmail ?? ""
    sshKeyPath = runtime.global.sshKeyPath ?? ""
    signingMode = runtime.global.signing.mode
    signingSSHKeyPath = runtime.global.signing.sshKeyPath ?? ""
    gpgKeyId = runtime.global.signing.gpgKeyId ?? ""
    gpgPrivateKeyPath = runtime.global.signing.gpgPrivateKeyPath ?? ""
    gpgPrivateKeyPassphrase = runtime.global.signing.gpgPrivateKeyPassphrase ?? ""
    globalToken = snapshot.credentials.globalToken ?? ""
    policyVersion = orchestrator.policyVersion

    let tokensByRepository = Dictionary(
      uniqueKeysWithValues: snapshot.credentials.repositoryTokens.map { ($0.repository, $0.token) }
    )
    repositoryOverrides = runtime.repositoryOverrides.map { override in
      TaskBoardRepositoryOverrideDraft(
        repository: override.repository,
        authorName: override.profile.authorName ?? "",
        authorEmail: override.profile.authorEmail ?? "",
        sshKeyPath: override.profile.sshKeyPath ?? "",
        signingMode: override.profile.signing.mode,
        signingSSHKeyPath: override.profile.signing.sshKeyPath ?? "",
        gpgKeyId: override.profile.signing.gpgKeyId ?? "",
        gpgPrivateKeyPath: override.profile.signing.gpgPrivateKeyPath ?? "",
        gpgPrivateKeyPassphrase: override.profile.signing.gpgPrivateKeyPassphrase ?? "",
        token: tokensByRepository[override.repository] ?? ""
      )
    }

    let runtimeRepositories = Set(runtime.repositoryOverrides.map(\.repository))
    let tokenOnlyOverrides = snapshot.credentials.repositoryTokens
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
          enabledAutomations: TaskBoardGitHubAutomationToggles(
            enabled: enabledAutomations.sorted(by: { $0.rawValue < $1.rawValue })
          )
        ),
        policyVersion: policyVersion
      ),
      runtimeConfig: TaskBoardGitRuntimeConfig(
        global: TaskBoardGitRuntimeProfile(
          authorName: normalized(authorName),
          authorEmail: normalized(authorEmail),
          sshKeyPath: normalized(sshKeyPath),
          signing: TaskBoardGitSigningConfig(
            mode: signingMode,
            sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
            gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
            gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
            gpgPrivateKeyPassphrase: signingMode == .gpg
              ? normalized(gpgPrivateKeyPassphrase)
              : nil
          )
        ),
        repositoryOverrides: repositoryOverrides
      ),
      credentials: TaskBoardGitHubCredentialSnapshot(
        globalToken: normalized(globalToken),
        repositoryTokens: repositoryTokens
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

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct TaskBoardRepositoryOverrideDraft: Equatable {
  var repository = ""
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var gpgKeyId = ""
  var gpgPrivateKeyPath = ""
  var gpgPrivateKeyPassphrase = ""
  var token = ""

  init(
    repository: String = "",
    authorName: String = "",
    authorEmail: String = "",
    sshKeyPath: String = "",
    signingMode: TaskBoardGitSigningMode = .none,
    signingSSHKeyPath: String = "",
    gpgKeyId: String = "",
    gpgPrivateKeyPath: String = "",
    gpgPrivateKeyPassphrase: String = "",
    token: String = ""
  ) {
    self.repository = repository
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.signingMode = signingMode
    self.signingSSHKeyPath = signingSSHKeyPath
    self.gpgKeyId = gpgKeyId
    self.gpgPrivateKeyPath = gpgPrivateKeyPath
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
        signing: TaskBoardGitSigningConfig(
          mode: signingMode,
          sshKeyPath: signingMode == .ssh ? normalized(signingSSHKeyPath) : nil,
          gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil,
          gpgPrivateKeyPath: signingMode == .gpg ? normalized(gpgPrivateKeyPath) : nil,
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
      || (signingMode == .ssh && normalized(signingSSHKeyPath) != nil)
      || (signingMode == .gpg && normalized(gpgKeyId) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKeyPath) != nil)
      || (signingMode == .gpg && normalized(gpgPrivateKeyPassphrase) != nil)
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum DispatchStatusFilterChoice: String, CaseIterable, Hashable {
  case all
  case new
  case planning
  case planReview
  case todo
  case inProgress
  case blocked
  case inReview
  case done

  init(status: TaskBoardStatus?) {
    switch status {
    case .none:
      self = .all
    case .new:
      self = .new
    case .planning:
      self = .planning
    case .planReview:
      self = .planReview
    case .todo:
      self = .todo
    case .inProgress:
      self = .inProgress
    case .blocked:
      self = .blocked
    case .inReview:
      self = .inReview
    case .done:
      self = .done
    }
  }

  var title: String {
    switch self {
    case .all: "All Items"
    case .new: "New"
    case .planning: "Planning"
    case .planReview: "Plan Review"
    case .todo: "Todo"
    case .inProgress: "In Progress"
    case .blocked: "Blocked"
    case .inReview: "In Review"
    case .done: "Done"
    }
  }

  var status: TaskBoardStatus? {
    switch self {
    case .all: nil
    case .new: .new
    case .planning: .planning
    case .planReview: .planReview
    case .todo: .todo
    case .inProgress: .inProgress
    case .blocked: .blocked
    case .inReview: .inReview
    case .done: .done
    }
  }
}

extension TaskBoardOrchestratorWorkflow {
  var title: String {
    switch self {
    case .defaultTask: "Default Task"
    case .prFix: "PR Fix"
    case .prReview: "PR Review"
    case .dependencyUpdate: "Dependency Update"
    }
  }
}

extension TaskBoardGitHubMergeMethod {
  var title: String {
    switch self {
    case .squash: "Squash"
    case .merge: "Merge Commit"
    case .rebase: "Rebase"
    }
  }
}

extension TaskBoardGitHubAutomation {
  var title: String {
    switch self {
    case .syncTaskBoard: "Sync Task Board"
    case .createBranch: "Create Branch"
    case .openPullRequest: "Open Pull Request"
    case .watchChecks: "Watch Checks"
    case .requestReview: "Request Review"
    case .autoMerge: "Auto Merge"
    }
  }
}
