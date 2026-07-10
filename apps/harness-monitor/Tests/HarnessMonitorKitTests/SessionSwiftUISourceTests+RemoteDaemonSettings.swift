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
}
