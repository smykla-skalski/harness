import HarnessMonitorKit
import SwiftUI

struct SettingsSecretsSection: View, SettingsTaskBoardEditingSurface {
  let store: HarnessMonitorStore
  let isActive: Bool
  @Binding private var taskBoardFormState: TaskBoardSettingsFormState

  var formState: Binding<TaskBoardSettingsFormState> { $taskBoardFormState }

  init(
    store: HarnessMonitorStore,
    formState: Binding<TaskBoardSettingsFormState>,
    isActive: Bool = true
  ) {
    self.store = store
    self.isActive = isActive
    _taskBoardFormState = formState
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      if let loadError {
        statusSection(message: loadError)
      } else if isLoading {
        loadingSection
      } else {
        globalGitCredentialsSection
        gitSigningSection
        credentialsSection
        repositoryOverridesHeader
        repositoryOverrideSections
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsSecretsRoot)
    .task(id: isActive) {
      guard isActive else { return }
      await loadSettingsIfNeeded()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      settingsPersistenceActionBar(
        reloadAccessibilityIdentifier: HarnessMonitorAccessibility.settingsSecretsReloadButton,
        saveAccessibilityIdentifier: HarnessMonitorAccessibility.settingsSecretsSaveButton
      )
    }
  }

  private func statusSection(message: String) -> some View {
    Section {
      Text(message)
        .foregroundStyle(.red)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsSecretsStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var loadingSection: some View {
    Section {
      ProgressView("Loading secrets...")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsSecretsStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var globalGitCredentialsSection: some View {
    Section {
      pathField(
        .keyFile(
          title: "SSH Key Path",
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSSHKeyPathField
        ),
        text: draftBinding.sshKeyPath
      )
      SettingsSecretField(
        title: "SSH Private Key",
        placeholder: "Paste SSH private key material",
        field: draftBinding.sshPrivateKey,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardSSHPrivateKeyField
      )
      SettingsSecretField(
        title: "SSH Key Passphrase",
        placeholder: "Optional passphrase",
        field: draftBinding.sshPrivateKeyPassphrase,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSSHKeyPassphraseField
      )
    } header: {
      Text("Git Keys")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("These values affect daemon-managed git authentication only")
    }
  }
}
