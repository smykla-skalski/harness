import Foundation
import Testing

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

  @Test("content pane no longer declares an in-content search field")
  func contentPaneOmitsInContentSearchField() throws {
    let source = try contentSource()
    #expect(!source.contains("var inContentSearchField"))
    #expect(!source.contains("dashboardReviewsInContentSearch"))
    #expect(!source.contains("Search reviews"))
  }

  @Test("top controls keep provenance, filters, and banners only")
  func topControlsPaneKeepsOnlySharedControls() throws {
    let source = try contentSource()
    #expect(source.contains("DashboardReviewsProvenanceBar("))
    #expect(source.contains("filterBar"))
    #expect(source.contains("transientBannerZone"))
    #expect(!source.contains("inContentSearchField"))
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
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent("DashboardReviewsRouteView+Content.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
