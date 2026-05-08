import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
  func testVisibleWindowsSuppressAdditionalLaunchActions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: true,
      restorePlan: .init(sessionIDs: ["sess-a"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .none)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testAlwaysOpenRecentOpensWelcomeWindow() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .alwaysOpenRecent,
      hasVisibleWindows: false
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsOpensTrackedSessions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: false,
      restorePlan: .init(sessionIDs: ["sess-a", "sess-b"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .sessions(["sess-a", "sess-b"]))
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsFallsBackToWelcomeWhenNothingRestored() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: false,
      restorePlan: .init(sessionIDs: [], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }

  func testLaunchBehaviorCopyDocumentsSessionWindowRelaunchEffects() throws {
    let copy = HarnessMonitorLaunchBehavior.closingBehaviorDescription
    let settingsSource = try uiPreviewableSourceFile(named: "Views/Settings/SettingsGeneralSection.swift")

    XCTAssertTrue(copy.contains("Command-W"))
    XCTAssertTrue(copy.contains("red close button"))
    XCTAssertTrue(copy.contains("left open at quit"))
    XCTAssertTrue(copy.contains("minimized session windows restore visible"))
    XCTAssertTrue(settingsSource.contains("HarnessMonitorLaunchBehavior.closingBehaviorDescription"))
  }

  private func uiPreviewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
