import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas reformat surface")
struct PolicyCanvasReformatSurfaceTests {
  @Test("top bar exposes a visible reformat action and command label")
  func topBarExposesVisibleReformatAction() throws {
    let chromeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let commandsSource = try appSourceFile(named: "App/HarnessMonitorAppCommands.swift")
    let uiTestAccessibilitySource = try uiTestSupportSourceFile(
      named: "HarnessMonitorUITestAccessibility+PolicyCanvas.swift"
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

  @Test("visible reformat actions use forced atomic reflow")
  func visibleReformatActionsUseForcedAtomicReflow() throws {
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let chromeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let dispatcherSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+Dispatchers.swift"
    )

    let forcedReformatRequest =
      "viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)"

    // Production reformat triggers route the new layout off-main before
    // publishing it (atomic reveal), and it strips saved/manual anchors so the
    // visible app action uses the same unconstrained engine pass as the lab.
    #expect(layoutSource.contains(forcedReformatRequest))
    #expect(chromeSource.contains(forcedReformatRequest))
    #expect(dispatcherSource.contains(forcedReformatRequest))
    #expect(!layoutSource.contains("viewModel.requestAtomicReflow()"))
    #expect(!chromeSource.contains("viewModel.requestAtomicReflow()"))
    #expect(!dispatcherSource.contains("viewModel.requestAtomicReflow()"))
    #expect(!layoutSource.contains("viewModel.reflowLayout("))
    #expect(!chromeSource.contains("viewModel.reflowLayout("))
    #expect(!dispatcherSource.contains("viewModel.reflowLayout("))
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
