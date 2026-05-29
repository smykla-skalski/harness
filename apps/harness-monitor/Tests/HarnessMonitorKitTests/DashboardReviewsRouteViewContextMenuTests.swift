import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews route view context menus")
struct DashboardReviewsRouteViewContextMenuTests {
  @Test("multi-select context menu offers a Copy N Links action")
  func multiSelectContextMenuOffersCopyNLinksAction() throws {
    let contextMenuSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContextMenu.swift"
    )

    // Defect 47: the single-item branch keeps "Open Pull Request" / "Copy
    // Link"; the multi-item branch must produce a "Copy N Links" Button
    // backed by the pure helper so the rule is unit-testable.
    #expect(contextMenuSource.contains("else if items.count > 1"))
    #expect(
      contextMenuSource.contains(
        "Button(dashboardReviewsCopyLinksMenuTitle(itemCount: items.count))"
      )
    )
    #expect(
      contextMenuSource.contains(
        "HarnessMonitorClipboard.copy(items.map(\\.url).joined(separator: \"\\n\"))"
      )
    )
  }

  @Test("copy links menu title pluralises with the selection count")
  func copyLinksMenuTitlePluralisesWithCount() {
    // Pure helper, so verify the exact title shape rather than introspecting
    // a SwiftUI Button. The helper is the single source of truth used by
    // both the context menu builder and any future surfaces.
    #expect(dashboardReviewsCopyLinksMenuTitle(itemCount: 2) == "Copy 2 Links")
    #expect(dashboardReviewsCopyLinksMenuTitle(itemCount: 5) == "Copy 5 Links")
    #expect(dashboardReviewsCopyLinksMenuTitle(itemCount: 42) == "Copy 42 Links")
  }

  @Test("GitHub path encoding preserves separators without split arrays")
  func githubPathEncodingPreservesSeparatorsWithoutSplitArrays() throws {
    #expect("src/My File.swift".dashboardReviewGitHubPathEncoded == "src/My%20File.swift")
    #expect("/src//Odd Name.swift/".dashboardReviewGitHubPathEncoded == "/src//Odd%20Name.swift/")

    let helperSource =
      try dashboardReviewsRouteSource(named: "DashboardReviewGitHubURLHelpers.swift")
    let extensionStart = try #require(helperSource.range(of: "extension String {"))
    let encodingSource = String(helperSource[extensionStart.lowerBound...])
    #expect(encodingSource.contains("encoded.reserveCapacity(count)"))
    #expect(encodingSource.contains("appendEncodedGitHubPathSegment"))
    #expect(!encodingSource.contains("split(separator: \"/\""))
    #expect(!encodingSource.contains("joined(separator: \"/\")"))
  }

  @Test("context menu primes selection state on menu open")
  func contextMenuPrimesSelectionOnMenuOpen() throws {
    let contextMenuSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContextMenu.swift"
    )
    let cacheSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Cache.swift"
    )

    // Defect 44: right-clicking an unselected row leaves `routeSelectedIDs`
    // stale because the list-level `forSelectionType:` API only updates the
    // closure argument, not the visible selection. The fallback primes the
    // state asynchronously so action handlers and the detail pane reflect
    // the menu's scope.
    #expect(contextMenuSource.contains("func primeSelectionForContextMenu"))
    #expect(contextMenuSource.contains("primeSelectionForContextMenu(items: items)"))
    #expect(contextMenuSource.contains("Task { @MainActor in"))
    #expect(contextMenuSource.contains("menuIDs.reserveCapacity(items.count)"))
    #expect(cacheSource.contains("seen.reserveCapacity(items.count)"))
    #expect(!contextMenuSource.contains("Set(items.map(\\.pullRequestID))"))
    #expect(!cacheSource.contains("Array(Set(items.map(\\.repository)))"))
  }

  @Test("commands and context menu expose pinning controls")
  func commandsAndContextMenuExposePinningControls() throws {
    let contextMenuSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContextMenu.swift"
    )
    let routeCommandsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Commands.swift"
    )
    let commandsSource = try dashboardReviewsAppSource(
      "apps/harness-monitor/Sources/HarnessMonitor/Commands/ReviewCommands.swift"
    )

    #expect(contextMenuSource.contains("let pinTitle = pinSelectionMenuTitle(for: items)"))
    #expect(contextMenuSource.contains("Button(pinTitle)"))
    #expect(contextMenuSource.contains("togglePinnedSelection(items: items)"))
    #expect(routeCommandsSource.contains("canTogglePinSelection"))
    #expect(routeCommandsSource.contains("togglePinnedSelection(items: commandItems)"))
    #expect(
      commandsSource.contains("Button(reviewCommands?.pinSelectionTitle ?? \"Pin Selection\")")
    )
    #expect(
      commandsSource.contains(
        ".keyboardShortcut(\"p\", modifiers: [.command, .option, .shift])"
      )
    )
  }

  @Test("activity snapshot exposes cache and missing check-link labels")
  func activitySnapshotExposesCacheAndMissingCheckLinkLabels() {
    let snapshot = DashboardReviewActivitySnapshot(
      pullRequestID: "pr-1",
      isRefreshing: true,
      actionTitle: "Approving",
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: true,
      lastAction: nil,
      policyStatus: nil,
      missingCheckRunURLCount: 2,
      totalCheckCount: 3,
      capabilities: ReviewsCapabilitiesResponse()
    )

    #expect(snapshot.cacheLabel == "Cached data")
    #expect(snapshot.checkLinkLabel == "2/3 check links missing")
  }
}
