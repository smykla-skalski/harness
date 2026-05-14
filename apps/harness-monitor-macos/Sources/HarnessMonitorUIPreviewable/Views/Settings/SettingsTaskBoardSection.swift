import AppKit
import HarnessMonitorKit
import SwiftUI

public struct SettingsTaskBoardSection: View {
  public let store: HarnessMonitorStore

  @State private var draft = TaskBoardGitSettingsDraft()
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var loadError: String?

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some View {
    Form {
      actionsSection

      if let loadError {
        Section {
          Text(loadError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardStatus)
        } header: {
          Text("Status")
            .harnessNativeFormSectionHeader()
        }
      } else if isLoading {
        Section {
          ProgressView("Loading Task Board settings...")
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardStatus)
        } header: {
          Text("Status")
            .harnessNativeFormSectionHeader()
        }
      } else {
        workflowSection
        projectSection
        automationSection
        gitDefaultsSection
        credentialsSection
        repositoryOverridesHeader
        repositoryOverrideSections
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRoot)
    .task { await loadSettings() }
  }

  private var actionsSection: some View {
    Section {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          HarnessMonitorAsyncActionButton(
            title: "Reload",
            tint: .secondary,
            variant: .bordered,
            isLoading: isLoading,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardReloadButton,
            action: loadSettings
          )
          HarnessMonitorAsyncActionButton(
            title: "Save Settings",
            tint: nil,
            variant: .prominent,
            isLoading: isSaving,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSaveButton,
            action: saveSettings
          )
          .disabled(isLoading || loadError != nil)
        }
      }
    } header: {
      Text("Actions")
        .harnessNativeFormSectionHeader()
    }
  }

  private var workflowSection: some View {
    Section {
      ForEach(TaskBoardOrchestratorWorkflow.allCases, id: \.self) { workflow in
        Toggle(workflow.title, isOn: workflowBinding(workflow))
      }
      Toggle("Dry Run by Default", isOn: $draft.dryRunDefault)
      Picker("Dispatch Status Filter", selection: $draft.dispatchStatusFilter) {
        ForEach(DispatchStatusFilterChoice.allCases, id: \.self) { choice in
          Text(choice.title).tag(choice)
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("Orchestrator Defaults")
        .harnessNativeFormSectionHeader()
    }
  }

  private var projectSection: some View {
    Section {
      pathField(
        title: "Project Directory",
        text: $draft.projectDir,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardProjectDirField,
        allowsDirectories: true,
        allowsFiles: false
      )
      TextField("Owner", text: $draft.owner)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardOwnerField)
      TextField("Repository", text: $draft.repo)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRepoField)
      pathField(
        title: "Checkout Path",
        text: $draft.checkoutPath,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardCheckoutPathField,
        allowsDirectories: true,
        allowsFiles: false
      )
      TextField("Default Branch", text: $draft.defaultBranch)
      TextField("Branch Prefix", text: $draft.branchPrefix)
      Picker("Merge Method", selection: $draft.mergeMethod) {
        ForEach(TaskBoardGitHubMergeMethod.allCases, id: \.self) { method in
          Text(method.title).tag(method)
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("GitHub Project")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These settings control the Task Board repository that the orchestrator targets.")
    }
  }

  private var automationSection: some View {
    Section {
      TextField("Managed Label", text: $draft.managedLabel)
      TextField("Auto Merge Label", text: $draft.autoMergeLabel)
      TextField("Needs Human Label", text: $draft.needsHumanLabel)
      TextField("Protected Path Label", text: $draft.protectedPathLabel)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Protected paths, one per line",
        text: $draft.protectedPathsText,
        minHeight: 88,
        accessibilityLabel: "Protected paths"
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardProtectedPathsField)
      ForEach(TaskBoardGitHubAutomation.allCases, id: \.self) { automation in
        Toggle(automation.title, isOn: automationBinding(automation))
      }
    } header: {
      Text("Automation")
        .harnessNativeFormSectionHeader()
    }
  }

  private var gitDefaultsSection: some View {
    Section {
      TextField("Author Name", text: $draft.authorName)
      TextField("Author Email", text: $draft.authorEmail)
      pathField(
        title: "SSH Key Path",
        text: $draft.sshKeyPath,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSSHKeyPathField,
        allowsDirectories: false,
        allowsFiles: true
      )
      Picker("Signing Mode", selection: $draft.signingMode) {
        ForEach(TaskBoardGitSigningMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.menu)
      if draft.signingMode == .ssh {
        pathField(
          title: "Signing SSH Key Path",
          text: $draft.signingSSHKeyPath,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSigningSSHKeyPathField,
          allowsDirectories: false,
          allowsFiles: true
        )
      }
      if draft.signingMode == .gpg {
        TextField("GPG Key ID", text: $draft.gpgKeyId)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardGPGKeyIDField)
      }
    } header: {
      Text("Git Identity Defaults")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These values affect daemon-managed git operations only.")
    }
  }

  private var credentialsSection: some View {
    Section {
      SecureField("GitHub Token", text: $draft.globalToken)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField)
    } header: {
      Text("Credentials")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Tokens are stored in your macOS Keychain. Leaving a token blank clears it.")
    }
  }

  private var repositoryOverridesHeader: some View {
    Section {
      Button {
        draft.repositoryOverrides.append(TaskBoardRepositoryOverrideDraft())
      } label: {
        Label("Add Repository Override", systemImage: "plus")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardAddOverrideButton)
    } header: {
      Text("Repository Overrides")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Use overrides for repo-specific identity or GitHub token values.")
    }
  }

  @ViewBuilder private var repositoryOverrideSections: some View {
    ForEach(Array(draft.repositoryOverrides.enumerated()), id: \.offset) { index, _ in
      Section {
        TextField("owner/repo", text: $draft.repositoryOverrides[index].repository)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideField(index)
          )
        TextField("Author Name", text: $draft.repositoryOverrides[index].authorName)
        TextField("Author Email", text: $draft.repositoryOverrides[index].authorEmail)
        pathField(
          title: "SSH Key Path",
          text: $draft.repositoryOverrides[index].sshKeyPath,
          accessibilityIdentifier: HarnessMonitorAccessibility
            .settingsTaskBoardRepositoryOverrideSSHKeyField(index),
          allowsDirectories: false,
          allowsFiles: true
        )
        Picker("Signing Mode", selection: $draft.repositoryOverrides[index].signingMode) {
          ForEach(TaskBoardGitSigningMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)
        if draft.repositoryOverrides[index].signingMode == .ssh {
          pathField(
            title: "Signing SSH Key Path",
            text: $draft.repositoryOverrides[index].signingSSHKeyPath,
            accessibilityIdentifier: HarnessMonitorAccessibility
              .settingsTaskBoardRepositoryOverrideSigningSSHKeyField(index),
            allowsDirectories: false,
            allowsFiles: true
          )
        }
        if draft.repositoryOverrides[index].signingMode == .gpg {
          TextField("GPG Key ID", text: $draft.repositoryOverrides[index].gpgKeyId)
        }
        SecureField("GitHub Token", text: $draft.repositoryOverrides[index].token)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideTokenField(index)
          )
        Button(role: .destructive) {
          draft.repositoryOverrides.remove(at: index)
        } label: {
          Label("Remove Override", systemImage: "trash")
        }
      } header: {
        Text("Repository Override \(index + 1)")
          .harnessNativeFormSectionHeader()
      }
    }
  }

  @ViewBuilder
  private func pathField(
    title: String,
    text: Binding<String>,
    accessibilityIdentifier: String,
    allowsDirectories: Bool,
    allowsFiles: Bool
  ) -> some View {
    LabeledContent(title) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        TextField(title, text: text)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier(accessibilityIdentifier)
        Button("Choose...") {
          if let path = selectPath(
            prompt: title,
            allowsDirectories: allowsDirectories,
            allowsFiles: allowsFiles
          ) {
            text.wrappedValue = path
          }
        }
      }
    }
  }

  private func workflowBinding(_ workflow: TaskBoardOrchestratorWorkflow) -> Binding<Bool> {
    Binding(
      get: { draft.enabledWorkflows.contains(workflow) },
      set: { isEnabled in
        if isEnabled {
          draft.enabledWorkflows.insert(workflow)
        } else {
          draft.enabledWorkflows.remove(workflow)
        }
      }
    )
  }

  private func automationBinding(_ automation: TaskBoardGitHubAutomation) -> Binding<Bool> {
    Binding(
      get: { draft.enabledAutomations.contains(automation) },
      set: { isEnabled in
        if isEnabled {
          draft.enabledAutomations.insert(automation)
        } else {
          draft.enabledAutomations.remove(automation)
        }
      }
    )
  }

  @MainActor
  private func loadSettings() async {
    isLoading = true
    defer { isLoading = false }

    do {
      let snapshot = try await store.taskBoardGitSettingsSnapshot()
      draft = TaskBoardGitSettingsDraft(snapshot: snapshot)
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  @MainActor
  private func saveSettings() async {
    isSaving = true
    defer { isSaving = false }

    let succeeded = await store.updateTaskBoardGitSettings(snapshot: draft.snapshot)
    if succeeded {
      loadError = nil
      await loadSettings()
    }
  }

  @MainActor
  private func selectPath(
    prompt: String,
    allowsDirectories: Bool,
    allowsFiles: Bool
  ) -> String? {
    let panel = NSOpenPanel()
    panel.prompt = "Choose"
    panel.message = prompt
    panel.canChooseDirectories = allowsDirectories
    panel.canChooseFiles = allowsFiles
    panel.canCreateDirectories = allowsDirectories
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    guard panel.runModal() == .OK else {
      return nil
    }
    return panel.url?.path
  }
}

private struct TaskBoardGitSettingsDraft: Equatable {
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
            gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil
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

private struct TaskBoardRepositoryOverrideDraft: Equatable {
  var repository = ""
  var authorName = ""
  var authorEmail = ""
  var sshKeyPath = ""
  var signingMode: TaskBoardGitSigningMode = .none
  var signingSSHKeyPath = ""
  var gpgKeyId = ""
  var token = ""

  init(
    repository: String = "",
    authorName: String = "",
    authorEmail: String = "",
    sshKeyPath: String = "",
    signingMode: TaskBoardGitSigningMode = .none,
    signingSSHKeyPath: String = "",
    gpgKeyId: String = "",
    token: String = ""
  ) {
    self.repository = repository
    self.authorName = authorName
    self.authorEmail = authorEmail
    self.sshKeyPath = sshKeyPath
    self.signingMode = signingMode
    self.signingSSHKeyPath = signingSSHKeyPath
    self.gpgKeyId = gpgKeyId
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
          gpgKeyId: signingMode == .gpg ? normalized(gpgKeyId) : nil
        )
      )
    )
  }

  var tokenOverride: TaskBoardGitHubRepositoryToken? {
    guard let repository = normalized(repository)?.lowercased(), let token = normalized(token) else {
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
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private enum DispatchStatusFilterChoice: String, CaseIterable, Hashable {
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

private extension TaskBoardOrchestratorWorkflow {
  var title: String {
    switch self {
    case .defaultTask: "Default Task"
    case .prFix: "PR Fix"
    case .prReview: "PR Review"
    case .dependencyUpdate: "Dependency Update"
    }
  }
}

private extension TaskBoardGitHubMergeMethod {
  var title: String {
    switch self {
    case .squash: "Squash"
    case .merge: "Merge Commit"
    case .rebase: "Rebase"
    }
  }
}

private extension TaskBoardGitHubAutomation {
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
