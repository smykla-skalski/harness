import XCTest

/// Round 3k follow-up: after the navigation-state cache landed the
/// AttributeGraph hot symbols still dominated the trace (find1<A> + UpdateStack
/// + propagate_dirty). NavigationSplitView's column animation drives 4 body
/// evals per toggle (intrinsic, route-independent — proven in round 3i), each
/// of which propagates the animating column width through the detail subtree.
/// `geometryGroup()` (macOS 14.1+) snapshots the detail's geometry so
/// descendants see a stable post-animation size during the column-width
/// transition, dropping per-frame layout cost for content that does not need
/// to interpolate. The column animation visual itself runs at the
/// NavigationSplitView level — geometryGroup on the detail subtree does not
/// change the column-reveal visual.
@MainActor
final class DashboardWindowDetailGeometryGroupTests: XCTestCase {
  func testDetailSubtreeIsolatesGeometryFromColumnAnimation() throws {
    let source = try dashboardWindowSource()

    XCTAssertTrue(
      source.contains(".geometryGroup()"),
      "DashboardWindowView must wrap its detail subtree in geometryGroup() to "
        + "isolate descendant layout from the column-width animation"
    )
  }

  func testGeometryGroupSitsInsideDetailNotOnTheLayout() throws {
    let source = try dashboardWindowSource()

    // Round 3g proved geometryGroup on the custom Layout (DashboardRetainedRouteLayout)
    // regresses. Anchor the modifier to the detail-closure scope by requiring it
    // to follow .navigationSubtitle which only appears in the detail closure body.
    let detailScope = source.range(of: ".navigationSubtitle(route.navigationSubtitle)")
    XCTAssertNotNil(detailScope, "Detail-closure anchor missing — test setup drifted")
    if let detailScope {
      let tail = String(source[detailScope.upperBound...])
      let geoIndex = tail.range(of: ".geometryGroup()")
      let closingBraceIndex = tail.range(of: "}")
      XCTAssertNotNil(geoIndex, "geometryGroup() must appear after navigationSubtitle")
      if let geoIndex, let closingBraceIndex {
        XCTAssertLessThan(
          geoIndex.lowerBound, closingBraceIndex.lowerBound,
          "geometryGroup() must sit inside the detail closure, before the closing brace"
        )
      }
    }
  }

  private func dashboardWindowSource() throws -> String {
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
      .appendingPathComponent("Views/Dashboard/DashboardWindowView.swift")
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
