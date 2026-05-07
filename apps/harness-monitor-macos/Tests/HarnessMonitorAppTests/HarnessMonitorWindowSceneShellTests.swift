import Foundation
import XCTest

final class HarnessMonitorWindowShellTests: XCTestCase {
  func testMainAndWorkspaceRootsDelegateSharedChromeToSceneShell() throws {
    let mainRootSource = try appSourceFile(named: "HarnessMonitorAppSceneSupport.swift")
    let mainRoot = try mainRootSource.slice(
      from: "struct HarnessMonitorWindowRootView",
      to: "private enum HarnessMonitorPerfScenarioStatus"
    )
    let workspaceRoot = try appSourceFile(named: "WorkspaceWindowRootView.swift")

    XCTAssertTrue(mainRoot.contains("HarnessMonitorWindowShell("))
    XCTAssertTrue(workspaceRoot.contains("HarnessMonitorWindowShell("))
    XCTAssertTrue(mainRoot.contains("WindowContentReadiness("))
    XCTAssertTrue(workspaceRoot.contains("WindowContentReadiness("))

    for modifier in duplicatedChromeModifiers {
      XCTAssertFalse(mainRoot.contains(modifier), "main root still owns \(modifier)")
      XCTAssertFalse(workspaceRoot.contains(modifier), "workspace root still owns \(modifier)")
    }
  }

  func testSceneShellOwnsSharedWindowChrome() throws {
    let shell = try appSourceFile(named: "HarnessMonitorWindowSceneShell.swift")

    for modifier in duplicatedChromeModifiers {
      XCTAssertTrue(shell.contains(modifier), "scene shell is missing \(modifier)")
    }
    XCTAssertTrue(shell.contains("HarnessMonitorBackdropDefaults.modeKey"))
    XCTAssertTrue(shell.contains("HarnessMonitorBackgroundDefaults.imageKey"))
    XCTAssertTrue(shell.contains("WindowContentReadinessGate("))
    XCTAssertTrue(shell.contains(".environment(\\.windowSurfaceContext"))
    XCTAssertTrue(shell.contains("HarnessMonitorAccessibility.windowShellState(windowID)"))
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
      ".toolbarBackgroundVisibility(.automatic, for: .windowToolbar)",
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
