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
        .components(separatedBy: "private var pairingInput").first
    )
    let spkiRow = try #require(
      profileRows.components(
        separatedBy: "HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {"
      ).dropFirst().first
    )
    let valueModifiers = try #require(
      spkiRow.components(separatedBy: "Text(profile.serverSPKISHA256.value)")
        .dropFirst().first?
        .components(separatedBy: ".clipped()").first
    )

    #expect(!profileRows.contains("LabeledContent(\"Server SPKI\")"))
    #expect(spkiRow.contains("Text(\"Server SPKI\")"))
    #expect(spkiRow.contains(".fixedSize(horizontal: true, vertical: false)"))
    #expect(valueModifiers.contains(".lineLimit(1)"))
    #expect(valueModifiers.contains(".truncationMode(.middle)"))
    #expect(valueModifiers.contains(".foregroundStyle(.secondary)"))
    #expect(valueModifiers.contains(".textSelection(.enabled)"))
    #expect(
      valueModifiers.contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)")
    )
    #expect(spkiRow.contains(".clipped()"))
    #expect(spkiRow.contains(".accessibilityElement(children: .combine)"))
    #expect(spkiRow.contains(".accessibilityLabel(\"Server SPKI\")"))
    #expect(spkiRow.contains(".accessibilityValue(profile.serverSPKISHA256.value)"))
  }
}
