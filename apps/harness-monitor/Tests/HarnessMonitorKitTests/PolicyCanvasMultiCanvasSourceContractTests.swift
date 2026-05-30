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
      dashboardFooterSource.contains(".foregroundStyle(isSelected ? Color.accentColor : Color.primary)")
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
    XCTAssertFalse(dashboardFooterSource.contains(".padding(.leading, HarnessMonitorTheme.spacingMD)"))
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
