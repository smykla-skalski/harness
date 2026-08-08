import XCTest

/// Round 3k follow-up: after the navigation-state cache landed the
/// AttributeGraph hot symbols still dominated the trace (find1<A> + UpdateStack
/// + propagate_dirty). NavigationSplitView's column animation drives 4 body
/// evals per toggle (intrinsic, route-independent — proven in round 3i), each
/// of which propagates the animating column width through the detail subtree.
/// `geometryGroup()` (macOS 14.1+) snapshots ordinary detail geometry so
/// descendants see a stable post-animation size during the column-width
/// transition. Agents is excluded because its nested split must receive the
/// parent geometry to honor its pane widths.
@MainActor
final class DashboardWindowDetailGeometryGroupTests: XCTestCase {
  func testOrdinaryDetailSubtreesIsolateGeometryFromColumnAnimation() throws {
    let source = try dashboardRouteContentSource()

    XCTAssertTrue(
      source.contains("DashboardRetainedRouteGeometryIsolation"),
      "ordinary Dashboard routes must isolate descendant layout from column animation"
    )
  }

  func testWholeDetailGeometryIsolationIsPreviewOnlyAndStable() throws {
    let source = try dashboardWindowSource()

    XCTAssertTrue(source.contains("isolatesWholeDetailGeometry: false"))
    XCTAssertTrue(
      source.contains(
        "DashboardWholeDetailGeometryIsolation(isEnabled: isolatesWholeDetailGeometry)"
      )
    )
  }

  func testAgentsNestedSplitReceivesParentGeometry() throws {
    let source = try dashboardRouteContentSource()
    let agentsStart = try XCTUnwrap(
      source.range(of: "DashboardRetainedAuxiliaryRoute(isVisible: isAgentsVisible)")
    )
    let auditStart = try XCTUnwrap(
      source.range(of: "DashboardRetainedAuxiliaryRoute(isVisible: isAuditVisible)")
    )
    let agentsSection = source[agentsStart.lowerBound..<auditStart.lowerBound]

    XCTAssertFalse(
      agentsSection.contains("DashboardRetainedRouteGeometryIsolation"),
      "Agents must receive parent geometry so its nested split stays visible"
    )
  }

  func testAgentsRouteAcceptsTheFullDashboardDetailProposal() throws {
    let source = try sourceFile(
      at: "Views/Agents/DashboardAgentsRouteView.swift"
    )

    XCTAssertTrue(
      source.contains(
        ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"
      ),
      "Agents must accept the retained layout's full detail proposal"
    )
  }

  private func dashboardRouteContentSource() throws -> String {
    try sourceFile(at: "Views/Dashboard/DashboardRouteContent.swift")
  }

  private func dashboardWindowSource() throws -> String {
    try sourceFile(at: "Views/Dashboard/DashboardWindowView.swift")
  }

  private func sourceFile(at path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
        .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
        .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
