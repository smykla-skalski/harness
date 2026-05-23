import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// The loading overlay must visually mark the reviews list as inert AND block
/// taps on the rows beneath the spinner. Both halves live in the source as
/// string-level contracts because the SwiftUI view tree is hard to introspect
/// directly. These tests assert the source shape so a future refactor that
/// drops `.disabled(routeIsLoading)` or the dimmed background lands as a
/// failure rather than silently restoring the original "click-through-the-
/// spinner" behaviour described in defect 45.
@Suite("Dashboard reviews loading overlay interactivity")
struct DashboardReviewsLoadingOverlayInteractivityTests {
  @Test("loading overlay disables the underlying list")
  func loadingOverlayDisablesUnderlyingList() throws {
    let source = try contentSource()
    // The whole `reviewsList` is disabled while loading so taps on the
    // underlying rows do not race the in-flight refresh.
    #expect(source.contains(".disabled(routeIsLoading)"))
  }

  @Test("loading overlay dims its background")
  func loadingOverlayDimsBackground() throws {
    let source = try contentSource()
    // A semi-opaque black fill behind the spinner makes the loading state
    // read as a foreground action instead of a thin spinner floating over
    // live content.
    #expect(source.contains("Color.black.opacity(0.18).ignoresSafeArea()"))
  }

  @Test("loading overlay wraps the spinner and dim in a ZStack with transition")
  func loadingOverlayWrapsInZStackWithTransition() throws {
    let source = try contentSource()
    // The opacity transition keeps the dim from popping in instantly. The
    // ZStack layers the dim under the spinner so they share the same
    // transition.
    #expect(source.contains("ZStack {"))
    #expect(source.contains(".transition(.opacity)"))
  }

  @Test("in-content search field exists and binds to searchText")
  func inContentSearchFieldExistsAndBindsToSearchText() throws {
    let source = try contentSource()
    // Defect 46: the toolbar `.searchable` is invisible to first-time users.
    // An in-content TextField bound to the same `$searchText` makes the
    // affordance discoverable from the sidebar.
    #expect(source.contains("var inContentSearchField"))
    #expect(source.contains("text: $searchText"))
    #expect(
      source.contains(
        "HarnessMonitorAccessibility.dashboardReviewsInContentSearch"
      )
    )
  }

  @Test("in-content search field renders inside contentPane above the list")
  func inContentSearchFieldRendersAboveList() throws {
    let source = try contentSource()
    // The field must live in the contentPane stack so it appears between the
    // provenance bar and the list, per defect 46. Asserting the textual
    // ordering keeps a future refactor from accidentally moving it into the
    // toolbar (where it would duplicate the existing `.searchable`).
    guard let searchOffset = source.range(of: "inContentSearchField")?.lowerBound,
      let listOffset = source.range(of: "contentListPane")?.lowerBound
    else {
      Issue.record("expected both inContentSearchField and contentListPane in source")
      return
    }
    #expect(searchOffset < listOffset)
  }

  @Test("accessibility constant for in-content search is namespaced")
  func accessibilityConstantForInContentSearchIsNamespaced() {
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsInContentSearch
        == "harness.dashboard.reviews.in-content-search"
    )
  }

  private func contentSource() throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent("DashboardReviewsRouteView+Content.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
