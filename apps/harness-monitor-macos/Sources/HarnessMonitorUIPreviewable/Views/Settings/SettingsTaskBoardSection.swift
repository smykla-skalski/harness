import HarnessMonitorKit
import SwiftUI

public struct SettingsTaskBoardSection: View {
  public let store: HarnessMonitorStore
  @Binding var navigationRequest: SettingsNavigationRequest?

  @State private var draft = TaskBoardGitSettingsDraft()
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var loadError: String?
  @State private var hasLoadedSettings = false
  @State private var pendingNavigationRequestID: UUID?

  public init(
    store: HarnessMonitorStore,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)
  ) {
    self.store = store
    _navigationRequest = navigationRequest
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
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
            .id(SettingsTaskBoardAnchor.githubProject)
          githubInboxSection
            .id(SettingsTaskBoardAnchor.githubInbox)
          SettingsTaskBoardHostSection(store: store)
          automationSection
          gitIdentitySection
          gitSigningSection
          credentialsSection
            .id(SettingsTaskBoardAnchor.credentials)
          repositoryOverridesHeader
          repositoryOverrideSections
        }
      }
      .settingsDetailFormStyle()
      .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
        actionsComposer
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRoot)
      .task { await loadSettings() }
      .onChange(of: navigationRequest, initial: true) { _, request in
        scrollToNavigationRequest(request, proxy: proxy)
      }
      .onChange(of: isLoading) { _, isLoading in
        guard !isLoading else { return }
        scrollToNavigationRequest(navigationRequest, proxy: proxy)
      }
    }
  }

  private var actionsComposer: some View {
    VStack(spacing: 0) {
      Divider()
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
            title: "Save",
            tint: nil,
            variant: .prominent,
            isLoading: isSaving,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSaveButton,
            action: saveSettings
          )
          .disabled(isLoading || loadError != nil)
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingXL)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .background(.background)
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
    SettingsTaskBoardInboxSection(draft: $draft)
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

  private func identityPrompt(_ detected: String?) -> Text? {
    guard let detected, !detected.isEmpty else { return nil }
    return Text(detected)
  }

  var draftBinding: Binding<TaskBoardGitSettingsDraft> {
    $draft
  }

  var isLoadingBinding: Binding<Bool> {
    $isLoading
  }

  var isSavingBinding: Binding<Bool> {
    $isSaving
  }

  var loadErrorBinding: Binding<String?> {
    $loadError
  }

  var hasLoadedSettingsBinding: Binding<Bool> {
    $hasLoadedSettings
  }

  var navigationRequestBinding: Binding<SettingsNavigationRequest?> {
    $navigationRequest
  }

  var pendingNavigationRequestIDBinding: Binding<UUID?> {
    $pendingNavigationRequestID
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
