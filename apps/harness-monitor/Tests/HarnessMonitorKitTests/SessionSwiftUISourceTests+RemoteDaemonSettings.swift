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

  @Test("Server SPKI middle-truncates while retaining its full selectable value")
  func serverSPKIRetainsFullSelectableValue() throws {
    let source = try sourceFile(at: "Views/Settings/SettingsRemoteDaemonSection.swift")
    let row = try #require(
      source.components(separatedBy: "LabeledContent(\"Server SPKI\") {").last?
        .components(separatedBy: "    }").first
    )

    #expect(row.contains("Text(profile.serverSPKISHA256.value)"))
    #expect(row.contains(".lineLimit(1)"))
    #expect(row.contains(".truncationMode(.middle)"))
    #expect(row.contains(".textSelection(.enabled)"))
  }
}
