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

    XCTAssertTrue(dashboardRouteSource.contains("DashboardPolicyCanvasRouteView("))
    XCTAssertTrue(dashboardPolicySource.contains("List(selection: $sidebarSelection)"))
    XCTAssertTrue(dashboardPolicySource.contains("PolicyCanvasView("))
    XCTAssertFalse(dashboardPolicySource.contains("SessionPolicyCanvasRedirectView"))
    XCTAssertTrue(dashboardPolicySource.contains("SessionContentDetailSplitView("))
    XCTAssertTrue(
      dashboardPolicySource.contains(
        "HarnessMonitorAccessibility.dashboardPolicyCanvasDetailDivider"
      )
    )
    XCTAssertTrue(dashboardPolicySource.contains(".task(id: refreshTaskID)"))
    XCTAssertTrue(dashboardPolicySource.contains("dashboardUI.connectionState"))
    XCTAssertFalse(dashboardPolicySource.contains("HSplitView {"))
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
    XCTAssertTrue(sessionRootSource.contains("windowNavigationHistory.requestDashboardRoute(route)"))
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
    let fileURL = repoRoot
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent(root)
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
