import Foundation
import XCTest

final class PolicyCanvasMultiCanvasSourceContractTests: XCTestCase {
  func testDashboardPolicyRouteOwnsSingleLiveEditor() throws {
    let dashboardRouteSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardRouteContent.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardRouteSource.contains("DashboardPolicyCanvasRouteView("))
    XCTAssertTrue(dashboardPolicySource.contains("DashboardPolicyCanvasFooterBar("))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterTab("))
    XCTAssertTrue(dashboardPolicySource.contains("PolicyCanvasView("))
    XCTAssertFalse(dashboardPolicySource.contains("SessionPolicyCanvasRedirectView"))
    XCTAssertFalse(dashboardPolicySource.contains("SessionContentDetailSplitView("))
    XCTAssertTrue(dashboardFooterSource.contains("ScrollView(.horizontal"))
    XCTAssertTrue(dashboardFooterSource.contains("dashboardPolicyCanvasFooterTabs"))
    XCTAssertTrue(dashboardPolicySource.contains(".task(id: refreshTaskID)"))
    XCTAssertTrue(dashboardPolicySource.contains("dashboardUI.connectionState"))
    XCTAssertFalse(dashboardPolicySource.contains("HSplitView {"))
  }

  func testDashboardPolicyRouteUsesIntegratedFooterCanvasTabChrome() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".scrollIndicators(.hidden)"))
    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterTabButtonStyle("))
    XCTAssertTrue(dashboardFooterSource.contains("NSCursor.pointingHand.push()"))
    XCTAssertTrue(dashboardFooterSource.contains(".frame(maxHeight: .infinity)"))
    XCTAssertTrue(dashboardFooterSource.contains(".overlay(alignment: .trailing)"))
    XCTAssertFalse(dashboardFooterSource.contains(".frame(height: 28)"))
    XCTAssertFalse(dashboardFooterSource.contains(".harnessPlainButtonStyle()"))
    XCTAssertFalse(dashboardFooterSource.contains("RoundedRectangle(cornerRadius: 6"))
    XCTAssertFalse(dashboardFooterSource.contains(".scrollContentBackground(.hidden)"))
    XCTAssertFalse(dashboardFooterSource.contains(".listStyle(.plain)"))
    XCTAssertFalse(dashboardFooterSource.contains(".listStyle(.sidebar)"))
  }

  func testDashboardPolicyRouteMovesCanvasMutationsIntoTabContextMenu() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".contextMenu {"))
    XCTAssertTrue(dashboardFooterSource.contains("duplicateCanvasFromTab(canvas)"))
    XCTAssertTrue(dashboardFooterSource.contains("renameCanvasFromTab(canvas)"))
    XCTAssertTrue(dashboardFooterSource.contains("deleteCanvasFromTab(canvas)"))
    XCTAssertFalse(dashboardFooterSource.contains("Button(\"Duplicate\", action: duplicateCanvas)"))
    XCTAssertFalse(dashboardFooterSource.contains("Button(\"Rename\", action: renameCanvas)"))
    XCTAssertFalse(
      dashboardFooterSource.contains("Button(\"Delete\", role: .destructive, action: deleteCanvas)")
    )
  }

  func testDashboardPolicyRouteUsesNeutralConsistentTabLabels() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains(".font(.callout.weight(.medium))"))
    XCTAssertFalse(dashboardFooterSource.contains("Circle()"))
    XCTAssertFalse(dashboardFooterSource.contains("tabIndicatorSize"))
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".foregroundStyle(isSelected ? Color.accentColor : Color.primary)"
      )
    )
  }

  func testDashboardPolicyRouteIntegratesCreateCanvasControlIntoTabStrip() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("private var createCanvasTab: some View"))
    XCTAssertTrue(dashboardFooterSource.contains("showsTrailingSeparator: false"))
    XCTAssertTrue(dashboardFooterSource.contains("Image(systemName: \"plus\")"))
    XCTAssertFalse(dashboardFooterSource.contains("private var createCanvasButton: some View"))
    XCTAssertFalse(
      dashboardFooterSource.contains(".padding(.horizontal, HarnessMonitorTheme.spacingMD)")
    )
    XCTAssertTrue(
      dashboardFooterSource.contains(".padding(.leading, HarnessMonitorTheme.spacingMD)")
    )
  }

  func testDashboardPolicyRouteMovesPolicyToolsIntoFooterCogMenu() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("DashboardPolicyCanvasFooterToolsMenuButton("))
    XCTAssertTrue(dashboardFooterSource.contains("PolicyCanvasToolsMenuContent("))
    XCTAssertTrue(dashboardFooterSource.contains("Image(systemName: \"gearshape\")"))
    XCTAssertTrue(
      dashboardFooterSource.contains("HarnessMonitorAccessibility.policyCanvasToolsButton")
    )
    XCTAssertTrue(dashboardFooterSource.contains(".menuIndicator(.hidden)"))
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "PolicyCanvasAutomationPolicySheet(viewModel: policyCanvasViewModel)"
      )
    )
    XCTAssertFalse(chromeSource.contains("PolicyCanvasTopBarToolsMenu("))
    XCTAssertFalse(
      chromeSource.contains("Label(\"Policy tools\", systemImage: \"ellipsis.circle\")")
    )
  }

  func testPolicyCanvasToolsMenuCanToggleAndHideMinimap() throws {
    let chromeSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasChromeViews.swift"
    )
    let minimapSource = try previewableSourceFile(
      at: "Views/PolicyCanvas/PolicyCanvasMinimapOverlay.swift"
    )

    XCTAssertTrue(chromeSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
    XCTAssertTrue(chromeSource.contains("Hide minimap"))
    XCTAssertTrue(chromeSource.contains("Show minimap"))
    XCTAssertTrue(minimapSource.contains(".contextMenu"))
    XCTAssertTrue(minimapSource.contains("Hide minimap"))
    XCTAssertTrue(minimapSource.contains("PolicyCanvasMinimapDefaults.isVisibleKey"))
  }

  func testDashboardPolicyRouteUsesSelectedTintForAdjacentTabSeparators() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertTrue(dashboardFooterSource.contains("var showsLeadingSeparator = false"))
    XCTAssertTrue(dashboardFooterSource.contains(".overlay(alignment: .leading)"))
    XCTAssertTrue(
      dashboardFooterSource.contains("selectedChromeColor(isPressed: configuration.isPressed)")
    )
    XCTAssertTrue(dashboardFooterSource.contains("showsLeadingSeparator ? borderWidth : 0"))
    XCTAssertFalse(
      dashboardFooterSource.contains(
        "return Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.34 : 0.24)"
      )
    )
  }

  func testDashboardPolicyRouteDoesNotMeasureFirstTabForLeadingFooterTint() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )

    XCTAssertFalse(dashboardFooterSource.contains("DashboardPolicyCanvasFooterFirstTabBoundsKey"))
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".anchorPreference(key: DashboardPolicyCanvasFooterFirstTabBoundsKey.self"
      )
    )
    XCTAssertFalse(
      dashboardFooterSource.contains(
        ".backgroundPreferenceValue(DashboardPolicyCanvasFooterFirstTabBoundsKey.self)"
      )
    )
  }

  func testDashboardPolicyRouteUsesOnlyPoliciesLoadingCopyInDetailPane() throws {
    let dashboardFooterSource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasFooterBar.swift"
    )
    let dashboardPolicySource = try previewableSourceFile(
      at: "Views/Dashboard/DashboardPolicyCanvasRouteView.swift"
    )

    XCTAssertFalse(dashboardFooterSource.contains("Loading canvases"))
    XCTAssertFalse(dashboardFooterSource.contains("footerStatusStrip(\"Loading canvases\""))
    XCTAssertTrue(dashboardPolicySource.contains("\"Loading Policies\""))
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "\"Policies will appear here once the workspace finishes loading.\""
      )
    )
    XCTAssertFalse(dashboardPolicySource.contains("\"Loading Policy Canvas\""))
    XCTAssertFalse(dashboardPolicySource.contains("\"Loading Policy Canvases\""))
    XCTAssertFalse(dashboardPolicySource.contains("\"The active policy canvas will appear here"))
  }

  func testSessionPolicyRouteRedirectsIntoDashboardPolicies() throws {
    let sessionColumnsSource = try previewableSourceFile(
      at: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let sessionRedirectSource = try previewableSourceFile(
      at: "Views/Sessions/SessionPolicyCanvasRedirectView.swift"
    )
    let sessionRootSource = try appSourceFile(
      at: "App/SessionWindowRootView.swift"
    )

    XCTAssertTrue(sessionColumnsSource.contains("SessionPolicyCanvasRedirectView()"))
    XCTAssertFalse(sessionColumnsSource.contains("PolicyCanvasView("))
    XCTAssertTrue(sessionRedirectSource.contains("openDashboardRoute(.policyCanvas)"))
    XCTAssertTrue(sessionRootSource.contains("\\.openDashboardRoute"))
    XCTAssertTrue(
      sessionRootSource.contains("windowNavigationHistory.requestDashboardRoute(route)"))
  }

  private func previewableSourceFile(at relativePath: String) throws -> String {
    try sourceFile(
      root: "Sources/HarnessMonitorUIPreviewable",
      relativePath: relativePath
    )
  }

  private func appSourceFile(at relativePath: String) throws -> String {
    try sourceFile(
      root: "Sources/HarnessMonitor",
      relativePath: relativePath
    )
  }

  private func sourceFile(root: String, relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent(root)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
