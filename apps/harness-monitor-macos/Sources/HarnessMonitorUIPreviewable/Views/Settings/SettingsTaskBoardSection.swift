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
        githubInboxSection
        SettingsTaskBoardHostSection(store: store)
        automationSection
        gitIdentitySection
        gitSigningSection
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
        .directory(
          title: "Project Directory",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardProjectDirField
        ),
        text: $draft.projectDir
      )
      TextField("Owner", text: $draft.owner)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardOwnerField)
      TextField("Repository", text: $draft.repo)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRepoField)
      pathField(
        .directory(
          title: "Checkout Path",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardCheckoutPathField
        ),
        text: $draft.checkoutPath
      )
      TextField("Default Branch", text: $draft.defaultBranch)
      TextField("Branch Prefix", text: $draft.branchPrefix)
      Picker("Merge Method", selection: $draft.mergeMethod) {
        ForEach(TaskBoardGitHubMergeMethod.allCases, id: \.self) { method in
          Text(method.title).tag(method)
        }
      }
      .pickerStyle(.menu)
      multilineField(
        title: "Requested Reviewers",
        placeholder: "usernames, one per line",
        text: $draft.requestedReviewersText,
        accessibilityIdentifier: HarnessMonitorAccessibility
          .settingsTaskBoardRequestedReviewersField
      )
      multilineField(
        title: "Requested Team Reviewers",
        placeholder: "team slugs, one per line",
        text: $draft.requestedTeamReviewersText,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardTeamReviewersField
      )
    } header: {
      Text("GitHub Project")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These settings control the automation repository that the orchestrator targets.")
    }
  }

  private var githubInboxSection: some View {
    Section {
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "owner/repo, one per line",
        text: $draft.githubInboxRepositoriesText,
        minHeight: 88,
        accessibilityLabel: "GitHub inbox repositories"
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsTaskBoardInboxRepositoriesField
      )
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "label, one per line (leave empty for all labels)",
        text: $draft.githubInboxLabelFilterText,
        minHeight: 66,
        accessibilityLabel: "GitHub inbox label filter"
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsTaskBoardInboxLabelFilterField
      )
    } header: {
      Text("GitHub Inbox")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        List repositories to import issues assigned to you and pull requests requesting your \
        review into Needs You. Add labels to restrict imports to issues that carry any of those \
        labels (case-insensitive). Leave the label list empty to import everything.
        """
      )
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

  private var gitIdentitySection: some View {
    Section {
      TextField(
        "Author Name",
        text: $draft.authorName,
        prompt: identityPrompt(draft.identityDefaults.gitConfig.userName)
      )
      TextField(
        "Author Email",
        text: $draft.authorEmail,
        prompt: identityPrompt(draft.identityDefaults.gitConfig.userEmail)
      )
      if shouldOfferAdoptDefaults {
        Button("Use my git config defaults", action: adoptGitConfigDefaults)
          .buttonStyle(.borderless)
      }
      pathField(
        .keyFile(
          title: "SSH Key Path",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSSHKeyPathField
        ),
        text: $draft.sshKeyPath
      )
      SettingsSecretField(
        title: "SSH Private Key",
        placeholder: "Paste SSH private key material",
        field: $draft.sshPrivateKey,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSSHPrivateKeyField
      )
      SettingsSecretField(
        title: "SSH Key Passphrase",
        placeholder: "Optional passphrase",
        field: $draft.sshPrivateKeyPassphrase,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSSHKeyPassphraseField
      )
    } header: {
      Text("Git Identity")
        .harnessNativeFormSectionHeader()
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("These values affect daemon-managed git operations only.")
        Text("Empty = use your git config defaults.")
      }
    }
  }

  private var gitSigningSection: some View {
    Section {
      Picker("Signing Mode", selection: $draft.signingMode) {
        ForEach(TaskBoardGitSigningMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.menu)
      if draft.signingMode == .ssh {
        pathField(
          .keyFile(
            title: "Signing SSH Key Path",
            accessibilityIdentifier: HarnessMonitorAccessibility
              .settingsTaskBoardSigningSSHKeyPathField
          ),
          text: $draft.signingSSHKeyPath
        )
        SettingsSecretField(
          title: "Signing SSH Private Key",
          placeholder: "Paste signing SSH private key material",
          field: $draft.signingSSHPrivateKey,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSigningSSHKeyField
        )
        SettingsSecretField(
          title: "Signing SSH Key Passphrase",
          placeholder: "Optional passphrase",
          field: $draft.signingSSHPrivateKeyPassphrase,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSigningSSHPassphraseField
        )
      }
      if draft.signingMode == .gpg {
        TextField("GPG Key ID", text: $draft.gpgKeyId)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardGPGKeyIDField)
        pathField(
          .keyFile(
            title: "GPG Private Key Path",
            accessibilityIdentifier: HarnessMonitorAccessibility
              .settingsTaskBoardGPGPrivateKeyPathField
          ),
          text: $draft.gpgPrivateKeyPath
        )
        SettingsSecretField(
          title: "GPG Private Key",
          placeholder: "Paste ASCII-armored GPG private key",
          field: $draft.gpgPrivateKey,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGPGPrivateKeyField
        )
        SettingsSecretField(
          title: "GPG Key Passphrase",
          placeholder: "Optional passphrase",
          field: $draft.gpgPrivateKeyPassphrase,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGPGPassphraseField
        )
      }
    } header: {
      Text("Signing")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "Choose how the daemon signs commits and tags it creates on your behalf."
      )
    }
  }

  private func identityPrompt(_ detected: String?) -> Text? {
    guard let detected, !detected.isEmpty else { return nil }
    return Text(detected)
  }

  private var shouldOfferAdoptDefaults: Bool {
    let gitConfig = draft.identityDefaults.gitConfig
    let hasDetectedName = gitConfig.userName?.isEmpty == false
    let hasDetectedEmail = gitConfig.userEmail?.isEmpty == false
    guard hasDetectedName || hasDetectedEmail else { return false }
    return draft.authorName.isEmpty || draft.authorEmail.isEmpty
  }

  private func adoptGitConfigDefaults() {
    let gitConfig = draft.identityDefaults.gitConfig
    if draft.authorName.isEmpty, let name = gitConfig.userName {
      draft.authorName = name
    }
    if draft.authorEmail.isEmpty, let email = gitConfig.userEmail {
      draft.authorEmail = email
    }
  }

  private var credentialsSection: some View {
    Section {
      SettingsSecretField(
        title: "GitHub Token",
        placeholder: "Personal access token",
        field: $draft.globalToken,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField
      )
      SettingsSecretField(
        title: "Todoist Token",
        placeholder: "Optional Todoist API token",
        field: $draft.todoistToken,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField
          + ".todoist"
      )
    } header: {
      Text("Credentials")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "Tokens are stored in your macOS Keychain. "
          + "Click the trash icon to clear a stored value."
      )
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
    ForEach(Array(draft.repositoryOverrides.enumerated()), id: \.element.id) { index, _ in
      Section {
        DisclosureGroup(repositoryOverrideTitle(index: index)) {
          TextField("owner/repo", text: $draft.repositoryOverrides[index].repository)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideField(index)
            )
          repositoryIdentityFields(index: index, override: $draft.repositoryOverrides[index])
          repositorySigningFields(index: index, override: $draft.repositoryOverrides[index])
          SettingsSecretField(
            title: "GitHub Token",
            placeholder: "Repository-specific token",
            field: $draft.repositoryOverrides[index].token,
            accessibilityIdentifier:
              HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideTokenField(index)
          )
          Button(role: .destructive) {
            draft.repositoryOverrides.remove(at: index)
          } label: {
            Label("Remove Override", systemImage: "trash")
          }
        }
      }
    }
  }

  private func repositoryOverrideTitle(index: Int) -> String {
    let slug = draft.repositoryOverrides[index].repository
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if slug.isEmpty {
      return "Repository Override \(index + 1)"
    }
    return slug
  }
}

extension SettingsTaskBoardSection {
  fileprivate func workflowBinding(_ workflow: TaskBoardOrchestratorWorkflow) -> Binding<Bool> {
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

  fileprivate func automationBinding(_ automation: TaskBoardGitHubAutomation) -> Binding<Bool> {
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
  fileprivate func loadSettings() async {
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
  fileprivate func saveSettings() async {
    isSaving = true
    defer { isSaving = false }

    let succeeded = await store.updateTaskBoardGitSettings(snapshot: draft.snapshot)
    if succeeded {
      loadError = nil
      await loadSettings()
    }
  }
}
