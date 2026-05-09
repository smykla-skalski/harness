import Foundation
import XCTest

final class HarnessMonitorWindowShellTests: XCTestCase {
  func testMainRootDelegatesSharedChromeToSceneShell() throws {
    let mainRootSource = try appSourceFile(named: "HarnessMonitorAppSceneSupport.swift")
    let mainRoot = try mainRootSource.slice(
      from: "struct HarnessMonitorWindowRootView",
      to: "private enum HarnessMonitorPerfScenarioStatus"
    )

    XCTAssertTrue(mainRoot.contains("HarnessMonitorWindowShell("))
    XCTAssertTrue(mainRoot.contains("WindowContentReadiness("))
    XCTAssertTrue(mainRoot.contains("windowToolbarBackgroundVisibility: nil"))
    XCTAssertTrue(mainRoot.contains("private var hostsSharedShellPresentation"))
    XCTAssertTrue(mainRoot.contains("HarnessMonitorConfirmationDialogModifier("))
    XCTAssertTrue(mainRoot.contains("HarnessMonitorSheetModifier("))
    XCTAssertTrue(mainRoot.contains("isEnabled: hostsSharedShellPresentation"))

    for modifier in duplicatedChromeModifiers {
      XCTAssertFalse(mainRoot.contains(modifier), "main root still owns \(modifier)")
    }
  }

  func testSceneShellOwnsSharedWindowChrome() throws {
    let shell = try appSourceFile(named: "HarnessMonitorWindowSceneShell.swift")

    for modifier in duplicatedChromeModifiers {
      XCTAssertTrue(shell.contains(modifier), "scene shell is missing \(modifier)")
    }
    XCTAssertTrue(shell.contains("OptionalWindowToolbarBackgroundVisibilityModifier("))
    XCTAssertTrue(shell.contains("HarnessMonitorBackdropDefaults.modeKey"))
    XCTAssertTrue(shell.contains("HarnessMonitorBackgroundDefaults.imageKey"))
    XCTAssertTrue(shell.contains("WindowContentReadinessGate("))
    XCTAssertTrue(shell.contains(".environment(\\.windowSurfaceContext"))
    XCTAssertTrue(shell.contains("HarnessMonitorAccessibility.windowShellState(windowID)"))
  }

  func testPerfScenarioStateMarkerIsNotInstalledWhenDisabled() throws {
    let source = try appSourceFile(named: "HarnessMonitorAppSceneSupport.swift")

    XCTAssertTrue(source.contains(".modifier(PerfScenarioStateMarker(text: perfScenarioStateText))"))
    XCTAssertTrue(source.contains("private struct PerfScenarioStateMarker: ViewModifier"))
    XCTAssertFalse(source.contains(".overlay {\n        if let perfScenarioStateText"))
  }

  private var duplicatedChromeModifiers: [String] {
    [
      ".writingToolsBehavior(.disabled)",
      "HarnessMonitorSceneAppearanceModifier(",
      "PinchToZoomTextSizeModifier()",
      "HarnessMonitorWindowBackdropModifier(",
      "WindowCommandScopeTrackingModifier(",
      ".harnessMonitorMCPWindowCommands(",
      "HarnessMonitorUITestAnimationModifier()",
    ]
  }

  private func appSourceFile(named name: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor/App")
      .appendingPathComponent(name)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}

private extension String {
  func slice(from startMarker: String, to endMarker: String) throws -> String {
    guard
      let start = range(of: startMarker)?.lowerBound,
      let end = range(of: endMarker, range: start..<endIndex)?.lowerBound
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return String(self[start..<end])
  }
}
