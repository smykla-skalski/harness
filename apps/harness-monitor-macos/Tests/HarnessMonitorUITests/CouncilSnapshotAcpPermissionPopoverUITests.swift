import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CouncilSnapshotAcpPermissionDecisionsUITests:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let previewPermissionKey = "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"
  private static let decisionID = "acp-permission:preview-acp-permission-1"

  func testCaptureDecisionsWindowForAcpPermissionPrompt() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewPermissionKey: "1",
      ]
    )
    openAgentsWindow(in: app)

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitForElement(decisionsWindow, timeout: Self.actionTimeout),
      "ACP permission prompts should route directly to Decisions"
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.decisionRow(Self.decisionID)),
        timeout: Self.actionTimeout
      ),
      "ACP permission decision should be visible in Decisions before snapshot capture"
    )
    XCTAssertFalse(
      element(in: app, identifier: Accessibility.acpPermissionModal).exists,
      "ACP permission flow should not show a separate modal surface"
    )

    saveWindowSnapshot(
      decisionsWindow,
      named: "council-acp-permission-decisions-window"
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
