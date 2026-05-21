import HarnessMonitorKit
import SwiftUI

struct SettingsTaskBoardSection: View, SettingsTaskBoardEditingSurface {
  let store: HarnessMonitorStore
  @Binding private var taskBoardFormState: TaskBoardSettingsFormState
  @Binding var navigationRequest: SettingsNavigationRequest?
  @State private var pendingNavigationRequestID: UUID?
  @State private var isFullyExpanded = false

  var formState: Binding<TaskBoardSettingsFormState> { $taskBoardFormState }

  init(
    store: HarnessMonitorStore,
    formState: Binding<TaskBoardSettingsFormState>,
    navigationRequest: Binding<SettingsNavigationRequest?> = .constant(nil)
  ) {
    self.store = store
    _taskBoardFormState = formState
    _navigationRequest = navigationRequest
  }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        if let loadError {
          statusSection(message: loadError)
        } else if isLoading {
          loadingSection
        } else {
          TaskBoardWorkflowSection(store: store, taskBoardFormState: $taskBoardFormState)
          TaskBoardProjectSection(store: store, taskBoardFormState: $taskBoardFormState)
            .id(SettingsTaskBoardAnchor.githubProject)
          TaskBoardMonitoredReposSection(
            store: store,
            taskBoardFormState: $taskBoardFormState,
            navigationRequest: $navigationRequest
          )
          .id(SettingsTaskBoardAnchor.githubInbox)
          if isFullyExpanded {
            githubInboxSection
            SettingsTaskBoardHostSection(store: store)
            automationSection
            authorIdentitySection
          }
        }
      }
      .settingsDetailFormStyle()
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRoot)
      .task { await loadSettingsIfNeeded() }
      .task { await expandAfterFirstFrame() }
      .onChange(of: navigationRequest, initial: true) { _, request in
        scrollToNavigationRequest(request, proxy: proxy)
      }
      .onChange(of: isLoading) { _, isLoading in
        guard !isLoading else { return }
        scrollToNavigationRequest(navigationRequest, proxy: proxy)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      settingsPersistenceActionBar(
        reloadAccessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardReloadButton,
        saveAccessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSaveButton
      )
    }
  }

  private func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
  }

  private func statusSection(message: String) -> some View {
    Section {
      Text(message)
        .foregroundStyle(.red)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var loadingSection: some View {
    Section {
      ProgressView("Loading Task Board settings...")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var githubInboxSection: some View {
    SettingsTaskBoardInboxSection(draft: draftBinding)
  }

  private var automationSection: some View {
    Section {
      TextField("Managed Label", text: draftBinding.managedLabel)
      TextField("Auto Merge Label", text: draftBinding.autoMergeLabel)
      TextField("Needs Human Label", text: draftBinding.needsHumanLabel)
      TextField("Protected Path Label", text: draftBinding.protectedPathLabel)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "Protected paths, one per line",
        text: draftBinding.protectedPathsText,
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

  private var authorIdentitySection: some View {
    Section {
      TextField(
        "Author Name",
        text: draftBinding.authorName,
        prompt: identityPrompt(draft.identityDefaults.gitConfig.userName)
      )
      TextField(
        "Author Email",
        text: draftBinding.authorEmail,
        prompt: identityPrompt(draft.identityDefaults.gitConfig.userEmail)
      )
      if shouldOfferAdoptDefaults {
        Button("Use my git config defaults", action: adoptGitConfigDefaults)
          .buttonStyle(.borderless)
      }
    } header: {
      Text("Git Author Identity")
        .harnessNativeFormSectionHeader()
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text("These values affect daemon-managed author identity only")
        Text("Empty = use your git config defaults")
      }
    }
  }

  private func identityPrompt(_ detected: String?) -> Text? {
    guard let detected, !detected.isEmpty else { return nil }
    return Text(detected)
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
    var updatedDraft = draft
    if updatedDraft.authorName.isEmpty, let name = gitConfig.userName {
      updatedDraft.authorName = name
    }
    if updatedDraft.authorEmail.isEmpty, let email = gitConfig.userEmail {
      updatedDraft.authorEmail = email
    }
    draftBinding.wrappedValue = updatedDraft
  }
}

private struct TaskBoardWorkflowSection: View, SettingsTaskBoardEditingSurface {
  let store: HarnessMonitorStore
  @Binding var taskBoardFormState: TaskBoardSettingsFormState
  var formState: Binding<TaskBoardSettingsFormState> { $taskBoardFormState }

  var body: some View {
    Section {
      ForEach(TaskBoardOrchestratorWorkflow.allCases, id: \.self) { workflow in
        Toggle(workflow.title, isOn: workflowBinding(workflow))
      }
      Toggle("Dry Run by Default", isOn: draftBinding.dryRunDefault)
      Picker("Dispatch Status Filter", selection: draftBinding.dispatchStatusFilter) {
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
}

private struct TaskBoardProjectSection: View, SettingsTaskBoardEditingSurface {
  let store: HarnessMonitorStore
  @Binding var taskBoardFormState: TaskBoardSettingsFormState
  var formState: Binding<TaskBoardSettingsFormState> { $taskBoardFormState }

  var body: some View {
    Section {
      pathField(
        .directory(
          title: "Project Directory",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardProjectDirField
        ),
        text: draftBinding.projectDir
      )
      TextField("Owner", text: draftBinding.owner)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardOwnerField)
      TextField("Repository", text: draftBinding.repo)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRepoField)
      pathField(
        .directory(
          title: "Checkout Path",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardCheckoutPathField
        ),
        text: draftBinding.checkoutPath
      )
      TextField("Default Branch", text: draftBinding.defaultBranch)
      TextField("Branch Prefix", text: draftBinding.branchPrefix)
      Picker("Merge Method", selection: draftBinding.mergeMethod) {
        ForEach(TaskBoardGitHubMergeMethod.allCases, id: \.self) { method in
          Text(method.title).tag(method)
        }
      }
      .pickerStyle(.menu)
      multilineField(
        title: "Requested Reviewers",
        placeholder: "usernames, one per line",
        text: draftBinding.requestedReviewersText,
        accessibilityIdentifier: HarnessMonitorAccessibility
          .settingsTaskBoardRequestedReviewersField
      )
      multilineField(
        title: "Requested Team Reviewers",
        placeholder: "team slugs, one per line",
        text: draftBinding.requestedTeamReviewersText,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardTeamReviewersField
      )
    } header: {
      Text("GitHub Project")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These settings control the automation repository that the orchestrator targets")
    }
  }
}

private struct TaskBoardMonitoredReposSection: View, SettingsTaskBoardEditingSurface {
  let store: HarnessMonitorStore
  @Binding var taskBoardFormState: TaskBoardSettingsFormState
  @Binding var navigationRequest: SettingsNavigationRequest?
  var formState: Binding<TaskBoardSettingsFormState> { $taskBoardFormState }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text("Monitored Repositories")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(
          draft.githubInboxRepositoryEntries.isEmpty
            ? "No repositories enabled for Task Board inbox monitoring"
            : "\(draft.githubInboxRepositoryEntries.count) repositories enabled for Task Board"
        )
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Button("Open Repositories") {
          navigationRequest = SettingsNavigationRequest(target: .section(.repositories))
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRepositoriesButton)
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardRepositoriesSummary)
    } header: {
      Text("Monitored Repositories")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Dependencies and Task Board share repository scope in Settings > Repositories.")
    }
  }
}
