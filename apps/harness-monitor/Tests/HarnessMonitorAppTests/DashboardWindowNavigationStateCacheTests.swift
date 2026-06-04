import XCTest

/// Round 3k stutter fix: `DashboardWindowView.windowNavigationState` was a
/// computed property that allocated a fresh `WindowNavigationState` AND a
/// fresh `WindowNavigationHandlers` reference on every body evaluation. The
/// toolbar and focused-scene publisher both consumed that value during column
/// toggles, so the repeated allocations showed up in the live-daemon trace's
/// AttributeGraph top-offenders (`find1<A>`, `propagate_dirty`). Caching the
/// state as `@State` and reusing the handlers reference via
/// `WindowNavigationState.updating(canGoBack:canGoForward:)` removes the
/// per-eval churn without changing native NavigationSplitView behavior.
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
