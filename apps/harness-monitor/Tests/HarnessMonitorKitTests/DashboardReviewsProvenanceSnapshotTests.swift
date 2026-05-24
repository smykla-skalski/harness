import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Coverage for the snapshot-derived strings that drive the new single-line
/// provenance bar. These exercise the four reconciliations the bar relies
/// on so the dot tint, source label, and warning copy never contradict.
@Suite("Dashboard reviews provenance snapshot derivations")
struct DashboardReviewsProvenanceSnapshotTests {
  @MainActor
  @Test("detailTitle no longer leads with the source title")
  func detailTitleDoesNotIncludeSourceTitle() {
    let fetchedAt = "2026-05-22T09:00:00Z"
    let now = Date(timeIntervalSince1970: 1_779_440_700)
    let snapshot = makeSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 2,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: []
      ),
      now: now
    )

    #expect(!snapshot.detailTitle.contains("Live daemon"))
    #expect(snapshot.detailTitle.hasPrefix("0 PRs"))
  }

  @MainActor
  @Test("warnings stack every applicable risk reason")
  func warningsStackEveryApplicableReason() {
    let fetchedAt = "2026-05-22T09:00:00Z"
    let staleNow = Date(timeIntervalSince1970: 1_779_442_200)
    let health = DashboardReviewsSyncHealth(
      totalRepositoryCount: 3,
      syncingRepositoryCount: 0,
      failedRepositories: ["acme/api"],
      staleRepositories: ["acme/web"]
    )

    let snapshot = makeSnapshot(
      fetchedAt: fetchedAt,
      fromCache: false,
      connectionState: .online,
      health: health,
      now: staleNow
    )

    #expect(snapshot.warnings.count == 3)
    #expect(snapshot.warnings.contains { $0.hasPrefix("Repository sync failed") })
    #expect(snapshot.warnings.contains { $0.hasPrefix("Fetched snapshot older than") })
    #expect(snapshot.warnings.contains { $0.hasPrefix("Repository sync stale") })
  }

  @MainActor
  @Test("Offline cache collapses to a single Daemon offline label")
  func offlineCacheSourceTitleCollapses() {
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: true,
      connectionState: .offline("daemon stopped"),
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 0,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: []
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    if case .offlineCache = snapshot.source {
      // expected
    } else {
      Issue.record("Expected .offlineCache source, got \(snapshot.source)")
    }
    #expect(snapshot.sourceTitle == "Daemon offline")
    #expect(snapshot.sourceSystemImage == "wifi.slash")
    #expect(snapshot.overallHealth == .danger)
  }

  @MainActor
  @Test("Last live snapshot also collapses to Daemon offline")
  func lastLiveSnapshotSourceTitleCollapses() {
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      connectionState: .offline("daemon stopped"),
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 1,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: []
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    if case .lastLiveSnapshot = snapshot.source {
      // expected
    } else {
      Issue.record("Expected .lastLiveSnapshot source, got \(snapshot.source)")
    }
    #expect(snapshot.sourceTitle == "Daemon offline")
    #expect(snapshot.sourceSystemImage == "wifi.slash")
    #expect(snapshot.overallHealth == .danger)
  }

  @MainActor
  @Test("Freshness risk on live source reconciles tint and label")
  func freshnessRiskOnLiveSourceReconcilesTintAndLabel() {
    // Live daemon, but a tracked repo is stale -> caution dot AND stale label.
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      connectionState: .online,
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 2,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: ["acme/repo"]
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    #expect(snapshot.hasFreshnessRisk)
    #expect(snapshot.source == .live)
    #expect(snapshot.sourceTitle == "Live daemon (stale)")
    #expect(snapshot.overallHealth == .caution)
  }

  @MainActor
  private func makeSnapshot(
    fetchedAt: String,
    fromCache: Bool,
    connectionState: HarnessMonitorStore.ConnectionState,
    health: DashboardReviewsSyncHealth,
    cacheMaxAgeSeconds: UInt64 = 600,
    perRepositoryIntervalSeconds: UInt64 = 300,
    now: Date
  ) -> DashboardReviewsProvenanceSnapshot {
    let items: [ReviewItem] = []
    return DashboardReviewsProvenanceSnapshot(
      response: ReviewsQueryResponse(
        fetchedAt: fetchedAt,
        fromCache: fromCache,
        summary: ReviewsSummary(items: items),
        items: items
      ),
      connectionState: connectionState,
      syncHealth: health,
      cacheMaxAgeSeconds: cacheMaxAgeSeconds,
      perRepositoryIntervalSeconds: perRepositoryIntervalSeconds,
      now: now
    )
  }
}
