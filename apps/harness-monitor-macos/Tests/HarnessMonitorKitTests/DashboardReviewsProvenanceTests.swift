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
    #expect(live.warnings.isEmpty)
    #expect(cache.source == .cache)
    #expect(offlineCache.source == .offlineCache("daemon stopped"))
    #expect(offlineCache.warnings == ["Daemon offline: daemon stopped"])
    #expect(lastLive.source == .lastLiveSnapshot("daemon stopped"))
    #expect(lastLive.warnings == ["Daemon offline: daemon stopped"])
    #expect(stale.fetchedSnapshotIsStale)
    #expect(stale.warnings == ["Fetched snapshot older than 10m (cache TTL)"])
  }

  @MainActor
  @Test("Staleness threshold respects a per-repository interval longer than cache TTL")
  func stalenessThresholdRespectsLongerPerRepositoryInterval() {
    let fetchedAt = "2026-05-22T09:00:00Z"
    // Daemon cache TTL stays at the 10-minute default; user picks a 50-minute
    // per-repository refresh cadence. Twenty minutes after the fetch the
    // scheduler is still on schedule, so the snapshot must not be flagged.
    let fetchedAtEpoch: TimeInterval = 1_779_440_400  // 2026-05-22T09:00:00Z
    let twentyMinutesAfter = Date(timeIntervalSince1970: fetchedAtEpoch + 1_200)
    let sixtyMinutesAfter = Date(timeIntervalSince1970: fetchedAtEpoch + 3_600)
    let health = DashboardReviewsSyncHealth(
      totalRepositoryCount: 5,
      syncingRepositoryCount: 0,
      failedRepositories: [],
      staleRepositories: []
    )

    let onSchedule = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: health,
      cacheMaxAgeSeconds: 600,
      perRepositoryIntervalSeconds: 3_000,
      now: twentyMinutesAfter
    )
    let pastCeiling = provenanceSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: health,
      cacheMaxAgeSeconds: 600,
      perRepositoryIntervalSeconds: 3_000,
      now: sixtyMinutesAfter
    )

    #expect(!onSchedule.fetchedSnapshotIsStale)
    #expect(onSchedule.warnings.isEmpty)
    #expect(pastCeiling.fetchedSnapshotIsStale)
    #expect(pastCeiling.warnings == ["Fetched snapshot older than 50m (per-repo sync interval)"])
  }

  @Test("Route wires provenance into toolbar centerpiece and detail surfaces")
  func routeWiresProvenanceIntoToolbarCenterpieceAndDetailSurfaces() throws {
    let routeSource = try dashboardSource(named: "DashboardReviewsRouteView.swift")
    let contentSource = try dashboardSource(named: "DashboardReviewsRouteView+Content.swift")
    let detailSource = try dashboardSource(named: "DashboardReviewDetailView.swift")
    let provenanceSource = try dashboardSource(named: "DashboardReviewsProvenance.swift")
    let toolbarItemsSource = try dashboardSource(named: "DashboardReviewsToolbarItems.swift")

    #expect(routeSource.contains("var normalizedPreferences: DashboardReviewsPreferences"))
    #expect(contentSource.contains("ToolbarItem(placement: .principal)"))
    #expect(contentSource.contains("DashboardReviewsToolbarCenterpiece(snapshot: routeProvenanceSnapshot)"))
    #expect(contentSource.contains("DashboardReviewsRefreshToolbarButton(onRefresh:"))
    #expect(contentSource.contains("DashboardReviewsInfoToolbarButton(snapshot: routeProvenanceSnapshot)"))
    #expect(!contentSource.contains("DashboardReviewsProvenanceBar("))
    #expect(!detailSource.contains("DashboardReviewProvenanceMiniBar"))
    #expect(provenanceSource.contains("var routeProvenanceSnapshot"))
    #expect(
      toolbarItemsSource.contains(
        "HarnessMonitorAccessibility.dashboardReviewsToolbarProvenance"
      )
    )
  }

  @MainActor
  private func provenanceSnapshot(
    fetchedAt: String,
    fromCache: Bool,
    connectionState: HarnessMonitorStore.ConnectionState,
    health: DashboardReviewsSyncHealth,
    cacheMaxAgeSeconds: UInt64 = 600,
    perRepositoryIntervalSeconds: UInt64 = 300,
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
      cacheMaxAgeSeconds: cacheMaxAgeSeconds,
      perRepositoryIntervalSeconds: perRepositoryIntervalSeconds,
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
