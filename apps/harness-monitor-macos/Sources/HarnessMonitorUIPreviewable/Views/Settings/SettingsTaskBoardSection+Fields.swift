import HarnessMonitorKit
import SwiftUI

extension SettingsTaskBoardSection {
  @ViewBuilder
  func repositoryIdentityFields(
    index: Int,
    override: Binding<TaskBoardRepositoryOverrideDraft>
  ) -> some View {
    TextField("Author Name", text: override.authorName)
    TextField("Author Email", text: override.authorEmail)
    pathField(
      .keyFile(
        title: "SSH Key Path",
        accessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideSSHKeyField(index)
      ),
      text: override.sshKeyPath
    )
    SettingsSecretField(
      title: "SSH Private Key",
      placeholder: "Paste SSH private key material",
      field: override.sshPrivateKey,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideSSHPrivateKeyField(index)
    )
    SettingsSecretField(
      title: "SSH Key Passphrase",
      placeholder: "Optional passphrase",
      field: override.sshPrivateKeyPassphrase,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.settingsTBRepoSSHKeyPassphraseField(index)
    )
  }

  @ViewBuilder
  func repositorySigningFields(
    index: Int,
    override: Binding<TaskBoardRepositoryOverrideDraft>
  ) -> some View {
    Picker("Signing Mode", selection: override.signingMode) {
      ForEach(TaskBoardGitSigningMode.allCases, id: \.self) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .pickerStyle(.menu)
    if override.wrappedValue.signingMode == .ssh {
      repositorySSHSigningFields(index: index, override: override)
    }
    if override.wrappedValue.signingMode == .gpg {
      repositoryGPGSigningFields(index: index, override: override)
    }
  }

  @ViewBuilder
  func repositorySSHSigningFields(
    index: Int,
    override: Binding<TaskBoardRepositoryOverrideDraft>
  ) -> some View {
    pathField(
      .keyFile(
        title: "Signing SSH Key Path",
        accessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideSigningSSHKeyField(index)
      ),
      text: override.signingSSHKeyPath
    )
    SettingsSecretField(
      title: "Signing SSH Private Key",
      placeholder: "Paste signing SSH private key material",
      field: override.signingSSHPrivateKey,
      accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBRepoSigningSSHKeyField(index)
    )
    SettingsSecretField(
      title: "Signing SSH Key Passphrase",
      placeholder: "Optional passphrase",
      field: override.signingSSHPrivateKeyPassphrase,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.settingsTBRepoSigningSSHPassphraseField(index)
    )
  }

  @ViewBuilder
  func repositoryGPGSigningFields(
    index: Int,
    override: Binding<TaskBoardRepositoryOverrideDraft>
  ) -> some View {
    TextField("GPG Key ID", text: override.gpgKeyId)
    pathField(
      .keyFile(
        title: "GPG Private Key Path",
        accessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideGPGPrivateKeyField(index)
      ),
      text: override.gpgPrivateKeyPath
    )
    SettingsSecretField(
      title: "GPG Private Key",
      placeholder: "Paste ASCII-armored GPG private key",
      field: override.gpgPrivateKey,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideGPGPrivateKeyMaterialField(
          index
        )
    )
    SettingsSecretField(
      title: "GPG Key Passphrase",
      placeholder: "Optional passphrase",
      field: override.gpgPrivateKeyPassphrase,
      accessibilityIdentifier:
        HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideGPGPassphraseField(index)
    )
  }

  func multilineField(
    title: String,
    placeholder: String,
    text: Binding<String>,
    accessibilityIdentifier: String
  ) -> some View {
    HarnessMonitorMultilineTextField<Never>(
      placeholder: placeholder,
      text: text,
      minHeight: 88,
      accessibilityLabel: title
    )
    .accessibilityIdentifier(accessibilityIdentifier)
  }
}
