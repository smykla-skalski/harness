import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas reformat surface")
struct PolicyCanvasReformatSurfaceTests {
  @Test("top bar exposes a visible reformat action and command label")
  func topBarExposesVisibleReformatAction() throws {
    let chromeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let commandsSource = try appSourceFile(named: "App/HarnessMonitorAppCommands.swift")
    let uiTestAccessibilitySource = try uiTestSupportSourceFile(
      named: "HarnessMonitorUITestAccessibility.swift"
    )

    #expect(
      HarnessMonitorAccessibility.policyCanvasReformatButton
        == "harness.policy-canvas.action.reformat"
    )
    #expect(chromeSource.contains("title: \"Reformat\""))
    #expect(
      chromeSource.contains(
        "accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasReformatButton"
      )
    )
    #expect(chromeSource.contains("Label(\"Reformat canvas\", systemImage: \"arrow.clockwise\")"))
    #expect(commandsSource.contains("Button(\"Reformat Canvas\")"))
    #expect(
      uiTestAccessibilitySource.contains(
        "static let policyCanvasReformatButton = \"harness.policy-canvas.action.reformat\""
      )
    )
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(
      contentsOf: appRoot.appendingPathComponent(
        "Sources/HarnessMonitorUIPreviewable/\(relativePath)"),
      encoding: .utf8
    )
  }

  private func appSourceFile(named relativePath: String) throws -> String {
    try String(
      contentsOf: appRoot.appendingPathComponent("Sources/HarnessMonitor/\(relativePath)"),
      encoding: .utf8
    )
  }

  private func uiTestSupportSourceFile(named relativePath: String) throws -> String {
    try String(
      contentsOf: appRoot.appendingPathComponent(
        "Tests/HarnessMonitorUITestSupport/\(relativePath)"),
      encoding: .utf8
    )
  }

  private var appRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
