import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

extension SessionSwiftUISourceTests {
  @Test("Remote forget confirmation blocks overlapping actions")
  func remoteForgetConfirmationBlocksOverlappingActions() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsRemoteDaemonSection.swift")
    let dialogSource = try #require(
      source.components(separatedBy: ".confirmationDialog(").last
    )

    #expect(dialogSource.contains("guard !actionState.isInFlight else { return }"))
    #expect(dialogSource.contains(".disabled(actionState.isInFlight)"))
  }

  @Test("Remote forget confirmation promises server credential revocation")
  func remoteForgetConfirmationDescribesServerRevocation() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsRemoteDaemonSection.swift")

    #expect(source.contains("revokes this client on the server"))
    #expect(source.contains("removes its bearer token from Keychain"))
    #expect(source.contains("returns to the local daemon mode"))
  }

  @Test("Server SPKI stays inline while retaining its full selectable value")
  func serverSPKIStaysInlineWithFullSelectableValue() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsRemoteDaemonSection.swift")
    let profileRows = try #require(
      source.components(separatedBy: "private func profileRows").last?
        .components(separatedBy: "  private var pairingInput").first
    )

    #expect(!profileRows.contains("LabeledContent(\"Server SPKI\")"))
    #expect(
      profileRows.contains(
        """
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
              Text("Server SPKI")
                .fixedSize(horizontal: true, vertical: false)
        """
      )
    )
    #expect(
      profileRows.contains(
        """
        Text(profile.serverSPKISHA256.value)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                .clipped()
        """
      )
    )
    #expect(
      profileRows.contains(
        """
        .accessibilityElement(children: .combine)
            .accessibilityLabel("Server SPKI")
            .accessibilityValue(profile.serverSPKISHA256.value)
        """
      )
    )
  }
}
