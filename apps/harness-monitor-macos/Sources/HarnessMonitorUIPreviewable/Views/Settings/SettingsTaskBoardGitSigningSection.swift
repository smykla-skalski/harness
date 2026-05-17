import HarnessMonitorKit
import SwiftUI

extension SettingsTaskBoardSection {
  var gitSigningSection: some View {
    Section {
      Picker("Signing Mode", selection: draftBinding.signingMode) {
        ForEach(TaskBoardGitSigningMode.allCases, id: \.self) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.menu)
      if draftBinding.wrappedValue.signingMode == .ssh {
        pathField(
          .keyFile(
            title: "Signing SSH Key Path",
            accessibilityIdentifier: HarnessMonitorAccessibility
              .settingsTaskBoardSigningSSHKeyPathField
          ),
          text: draftBinding.signingSSHKeyPath
        )
        SettingsSecretField(
          title: "Signing SSH Private Key",
          placeholder: "Paste signing SSH private key material",
          field: draftBinding.signingSSHPrivateKey,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSigningSSHKeyField
        )
        SettingsSecretField(
          title: "Signing SSH Key Passphrase",
          placeholder: "Optional passphrase",
          field: draftBinding.signingSSHPrivateKeyPassphrase,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTBSigningSSHPassphraseField
        )
      }
      if draftBinding.wrappedValue.signingMode == .gpg {
        TextField("GPG Key ID", text: draftBinding.gpgKeyId)
          .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardGPGKeyIDField)
        pathField(
          .keyFile(
            title: "GPG Private Key Path",
            accessibilityIdentifier: HarnessMonitorAccessibility
              .settingsTaskBoardGPGPrivateKeyPathField
          ),
          text: draftBinding.gpgPrivateKeyPath
        )
        SettingsSecretField(
          title: "GPG Private Key",
          placeholder: "Paste ASCII-armored GPG private key",
          field: draftBinding.gpgPrivateKey,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGPGPrivateKeyField
        )
        SettingsSecretField(
          title: "GPG Key Passphrase",
          placeholder: "Optional passphrase",
          field: draftBinding.gpgPrivateKeyPassphrase,
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
}
