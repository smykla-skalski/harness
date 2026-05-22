import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews provenance")
struct DashboardReviewsProvenanceTests {
  @MainActor
  @Test("Snapshot distinguishes live cache offline and stale states")
  func snapshotDistinguishesLiveCacheOfflineAndStaleStates() {
    let fetchedAt = "2026-05-22T09:00:00Z"
    let freshNow = Date(timeIntervalSince1970: 1_779_440_700)
    let staleNow = Date(timeIntervalSince1970: 1_779_442_200)
    let health = DashboardReviewsSyncHealth(
      totalRepositoryCount: 2,
      syncingRepositoryCount: 0,
      failedRepositories: [],
      staleRepositories: []
    )

    let live = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: health,
      now: freshNow
    )
    let cache = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: true,
      connectionState: .online,
      health: health,
      now: freshNow
    )
    let offlineCache = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: true,
      connectionState: .offline("daemon stopped"),
      health: health,
      now: freshNow
    )
    let lastLive = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .offline("daemon stopped"),
      health: health,
      now: freshNow
    )
    let stale = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: health,
      now: staleNow
    )

    #expect(live.source == .live)
    #expect(live.warningTitle == nil)
    #expect(cache.source == .cache)
    #expect(offlineCache.source == .offlineCache("daemon stopped"))
    #expect(offlineCache.warningTitle == "Daemon offline: daemon stopped")
    #expect(lastLive.source == .lastLiveSnapshot("daemon stopped"))
    #expect(lastLive.warningTitle == "Daemon offline: daemon stopped")
    #expect(stale.fetchedSnapshotIsStale)
    #expect(stale.warningTitle == "Fetched snapshot exceeds 10m")
  }

  @Test("Route wires provenance into list and detail surfaces")
  func routeWiresProvenanceIntoListAndDetailSurfaces() throws {
    let routeSource = try dashboardSource(named: "DashboardReviewsRouteView.swift")
    let contentSource = try dashboardSource(named: "DashboardReviewsRouteView+Content.swift")
    let detailSource = try dashboardSource(named: "DashboardReviewDetailView.swift")
    let provenanceSource = try dashboardSource(named: "DashboardReviewsProvenance.swift")

    #expect(routeSource.contains("var normalizedPreferences: DashboardReviewsPreferences"))
    #expect(contentSource.contains("DashboardReviewsProvenanceBar("))
    #expect(contentSource.contains("snapshot: routeProvenanceSnapshot"))
    #expect(contentSource.contains("provenance: routeProvenanceSnapshot"))
    #expect(detailSource.contains("DashboardReviewProvenanceMiniBar("))
    #expect(provenanceSource.contains("var routeProvenanceSnapshot"))
    #expect(
      provenanceSource.contains(
        "HarnessMonitorAccessibility.dashboardReviewsProvenance"
      )
    )
  }

  @MainActor
  private func provenanceSnapshot(
    fetchedAt: String,
    fromCache: Bool,
    connectionState: HarnessMonitorStore.ConnectionState,
    health: DashboardReviewsSyncHealth,
    now: Date
  ) -> DashboardReviewsProvenanceSnapshot {
    DashboardReviewsProvenanceSnapshot(
      response: ReviewsQueryResponse(
        fetchedAt: fetchedAt,
        fromCache: fromCache,
        summary: ReviewsSummary(items: []),
        items: []
      ),
      connectionState: connectionState,
      syncHealth: health,
      cacheMaxAgeSeconds: 600,
      perRepositoryIntervalSeconds: 300,
      now: now
    )
  }

  private func dashboardSource(named fileName: String) throws -> String {
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
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
