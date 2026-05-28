import XCTest

/// Round 3k stutter fix: `DashboardWindowView.windowNavigationState` was a
/// computed property that allocated a fresh `WindowNavigationState` AND a
/// fresh `WindowNavigationHandlers` reference on every body evaluation. With
/// 4 body evals per column toggle (per the live-daemon audit's app-trace)
/// and three call sites (toolbar, trackpad swipe modifier, focused-scene
/// publisher) that churn was 12 fresh struct + 12 fresh handler allocations
/// per uncollapse, each carrying two fresh closures capturing `history`.
/// AttributeGraph dominates the trace top-offenders (`find1<A>` 534ms across
/// the run), so caching this state as `@State` and reusing the handlers
/// reference via `WindowNavigationState.updating(canGoBack:canGoForward:)`
/// removes the per-eval churn without changing native NavigationSplitView
/// behavior.
@MainActor
final class DashboardWindowNavigationStateCacheTests: XCTestCase {
  func testWindowNavigationStateUsesCachedStorage() throws {
    let source = try dashboardWindowSource()

    XCTAssertTrue(
      source.contains("@State private var navigationStateStorage"),
      "DashboardWindowView must cache WindowNavigationState in @State storage"
    )
  }

  func testWindowNavigationStateAccessorUsesUpdatingHelper() throws {
    let source = try dashboardWindowSource()

    XCTAssertTrue(
      source.contains("navigationStateStorage.updating("),
      "DashboardWindowView accessor must derive from the cached storage via .updating(...)"
    )
  }

  func testBodyDoesNotAllocateFreshWindowNavigationStatePerEval() throws {
    let source = try dashboardWindowSource()

    XCTAssertFalse(
      source.contains("let navigationState = WindowNavigationState("),
      "Fresh WindowNavigationState allocations in the accessor reintroduce focused-value churn"
    )
  }

  func testNavigationHandlersInstalledOnce() throws {
    let source = try dashboardWindowSource()

    XCTAssertTrue(
      source.contains("navigationStateStorage.setHandlers("),
      "Handlers must be installed once on the cached storage, not rebuilt per body eval"
    )
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
