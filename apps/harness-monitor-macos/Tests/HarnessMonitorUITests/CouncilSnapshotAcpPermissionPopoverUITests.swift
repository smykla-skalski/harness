import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CouncilSnapshotAcpPermissionPopoverUITests:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let previewPermissionKey = "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"

  func testCaptureAgentsWindowWithAcpPermissionPopover() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewPermissionKey: "1",
      ]
    )
    openAgentsWindow(in: app)

    let permissionPopover = element(in: app, identifier: Accessibility.acpPermissionModal)
    XCTAssertTrue(
      waitForElement(permissionPopover, timeout: Self.actionTimeout),
      "ACP permission popover should be visible before council snapshot capture"
    )

    saveWindowSnapshot(
      window(in: app, containing: permissionPopover),
      named: "council-acp-permission-popover"
    )
  }

  private func saveWindowSnapshot(_ window: XCUIElement, named name: String) {
    guard window.exists else {
      XCTFail("Cannot capture council snapshot for \(name): target window does not exist.")
      return
    }
    let screenshot = window.screenshot()
    let artifactsDirectory =
      diagnosticsArtifactsDirectory(for: Self.artifactsDirectoryKey)
      ?? URL(fileURLWithPath: "/tmp/harness-monitor-council-snapshots", isDirectory: true)
    let outputURL = artifactsDirectory.appendingPathComponent("\(name).png")
    do {
      try FileManager.default.createDirectory(
        at: artifactsDirectory,
        withIntermediateDirectories: true
      )
      try screenshot.pngRepresentation.write(to: outputURL)
    } catch {
      XCTFail("Failed to save snapshot \(outputURL.path): \(error)")
    }
  }
}
