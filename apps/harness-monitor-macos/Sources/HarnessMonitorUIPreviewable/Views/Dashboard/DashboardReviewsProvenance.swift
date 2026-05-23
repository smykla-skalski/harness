import Foundation
import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsProvenanceSnapshot: Equatable {
  enum Source: Equatable {
    case live
    case cache
    case offlineCache(String)
    case lastLiveSnapshot(String)
    case empty
  }

  /// Aggregate health state combining source freshness with per-repo sync
  /// health. Drives both the dot tint and the source-label weight so they
  /// never contradict each other.
  enum OverallHealth: Equatable {
    case success
    case caution
    case danger
  }

  let source: Source
  let fetchedAt: String
  let fetchedDate: Date?
  let fetchedSnapshotIsStale: Bool
  let cacheMaxAgeSeconds: UInt64
  let perRepositoryIntervalSeconds: UInt64
  /// Ceiling beyond which the aggregate snapshot is considered stale. Set to
  /// the larger of the daemon's cache TTL and the user's chosen per-repository
  /// refresh interval so users who pick a longer cadence don't see a "10m"
  /// warning fire every cycle while their schedule is on time.
  let freshnessCeilingSeconds: UInt64
  let repositoryCount: Int
  let syncingRepositoryCount: Int
  let failedRepositories: [String]
  let staleRepositories: [String]
  let itemCount: Int

  init(
    response: ReviewsQueryResponse,
    connectionState: HarnessMonitorStore.ConnectionState,
    syncHealth: DashboardReviewsSyncHealth,
    cacheMaxAgeSeconds: UInt64,
    perRepositoryIntervalSeconds: UInt64,
    now: Date = .now
  ) {
    fetchedAt = response.fetchedAt
    fetchedDate = Self.parseDate(response.fetchedAt)
    let ceiling = max(cacheMaxAgeSeconds, perRepositoryIntervalSeconds)
    freshnessCeilingSeconds = ceiling
    fetchedSnapshotIsStale =
      fetchedDate.map {
        now.timeIntervalSince($0) > TimeInterval(ceiling)
      } ?? false
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
    self.perRepositoryIntervalSeconds = perRepositoryIntervalSeconds
    repositoryCount = syncHealth.totalRepositoryCount
    syncingRepositoryCount = syncHealth.syncingRepositoryCount
    failedRepositories = syncHealth.failedRepositories
    staleRepositories = syncHealth.staleRepositories
    itemCount = response.items.count
    source = Self.resolveSource(
      response: response,
      connectionState: connectionState
    )
  }

  var sourceTitle: String {
    switch source {
    case .live:
      hasFreshnessRisk ? "Live daemon (stale)" : "Live daemon"
    case .cache:
      "Persisted cache"
    case .offlineCache, .lastLiveSnapshot:
      "Daemon offline"
    case .empty:
      "No data"
    }
  }

  var sourceSystemImage: String {
    switch source {
    case .live:
      "checkmark.circle"
    case .cache:
      "archivebox"
    case .offlineCache, .lastLiveSnapshot:
      "wifi.slash"
    case .empty:
      "shippingbox"
    }
  }

  var overallHealth: OverallHealth {
    switch source {
    case .live:
      hasFreshnessRisk ? .caution : .success
    case .empty:
      .caution
    case .cache:
      hasFreshnessRisk ? .danger : .caution
    case .offlineCache, .lastLiveSnapshot:
      .danger
    }
  }

  var sourceTint: Color {
    switch overallHealth {
    case .success:
      HarnessMonitorTheme.success
    case .caution:
      HarnessMonitorTheme.caution
    case .danger:
      HarnessMonitorTheme.danger
    }
  }

  var hasFreshnessRisk: Bool {
    fetchedSnapshotIsStale || !failedRepositories.isEmpty || !staleRepositories.isEmpty
  }

  var fetchedAtTitle: String {
    guard !fetchedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Never fetched"
    }
    return formatTimestamp(fetchedAt)
  }

  var fetchedAgeTitle: String {
    guard let fetchedDate else { return "unknown age" }
    return reviewsRelativeFormatter.localizedString(for: fetchedDate, relativeTo: .now)
  }

  var cachePolicyTitle: String {
    "cache max \(harnessMonitorDuration(cacheMaxAgeSeconds))"
  }

  var repositoryPolicyTitle: String {
    "repo sync \(harnessMonitorDuration(perRepositoryIntervalSeconds))"
  }

  /// Compact tail used to the right of the source label in the single-line
  /// status bar. Intentionally omits `sourceTitle` so it doesn't repeat the
  /// label rendered immediately to its left.
  var detailTitle: String {
    var parts = ["\(itemCount) PRs"]
    if fetchedDate != nil || !fetchedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(fetchedAgeTitle)
    }
    if syncingRepositoryCount > 0 {
      parts.append("syncing \(syncingRepositoryCount)")
    }
    if !failedRepositories.isEmpty {
      parts.append("\(failedRepositories.count) failed")
    }
    if !staleRepositories.isEmpty {
      parts.append("\(staleRepositories.count) stale")
    }
    return parts.joined(separator: " · ")
  }

  /// All applicable warnings stacked, not just the first match. Surfaced as
  /// separate Label rows in the info popover.
  var warnings: [String] {
    var lines: [String] = []
    if case .offlineCache(let reason) = source {
      lines.append("Daemon offline: \(reason)")
    }
    if case .lastLiveSnapshot(let reason) = source {
      lines.append("Daemon offline: \(reason)")
    }
    if !failedRepositories.isEmpty {
      lines.append("Repository sync failed for \(repositoryList(failedRepositories))")
    }
    if fetchedSnapshotIsStale {
      lines.append("Fetched snapshot exceeds \(harnessMonitorDuration(freshnessCeilingSeconds))")
    }
    if !staleRepositories.isEmpty {
      lines.append("Repository sync stale for \(repositoryList(staleRepositories))")
    }
    return lines
  }

  private static func resolveSource(
    response: ReviewsQueryResponse,
    connectionState: HarnessMonitorStore.ConnectionState
  ) -> Source {
    if response.items.isEmpty && response.fetchedAt.isEmpty {
      return .empty
    }
    if case .offline(let reason) = connectionState {
      return response.fromCache ? .offlineCache(reason) : .lastLiveSnapshot(reason)
    }
    return response.fromCache ? .cache : .live
  }

  private static func parseDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let regular = ISO8601DateFormatter()
    regular.formatOptions = [.withInternetDateTime]
    return fractional.date(from: value) ?? regular.date(from: value)
  }

  func repositoryList(_ repositories: [String]) -> String {
    let visible = repositories.prefix(3).joined(separator: ", ")
    guard repositories.count > 3 else { return visible }
    return "\(visible), +\(repositories.count - 3)"
  }
}

extension DashboardReviewsRouteView {
  var routeProvenanceSnapshot: DashboardReviewsProvenanceSnapshot {
    DashboardReviewsProvenanceSnapshot(
      response: routeResponse,
      connectionState: store.connectionState,
      syncHealth: routeSyncHealth,
      cacheMaxAgeSeconds: normalizedPreferences.cacheMaxAgeSeconds,
      perRepositoryIntervalSeconds: normalizedPreferences.perRepositoryIntervalSeconds
    )
  }
}

struct DashboardReviewsProvenanceBar: View {
  let snapshot: DashboardReviewsProvenanceSnapshot
  let onRefresh: () -> Void

  @State private var isInfoPopoverPresented = false

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      healthDot
      Text(snapshot.sourceTitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(snapshot.sourceTint)
        .lineLimit(1)
      Text("·")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      Text(snapshot.detailTitle)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      refreshButton
      infoButton
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .harnessFloatingControlGlass(cornerRadius: 8, tint: snapshot.sourceTint)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsProvenance)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Review data provenance")
    .accessibilityValue("\(snapshot.sourceTitle) · \(snapshot.detailTitle)")
  }

  private var healthDot: some View {
    Circle()
      .fill(snapshot.sourceTint)
      .frame(width: 8, height: 8)
      .accessibilityHidden(true)
  }

  private var refreshButton: some View {
    Button(action: onRefresh) {
      Image(systemName: "arrow.clockwise")
        .imageScale(.medium)
        .frame(width: 18, height: 18)
    }
    .frame(width: 28, height: 28)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .help("Refresh review data")
    .accessibilityLabel("Refresh review data")
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsRefreshButton)
  }

  private var infoButton: some View {
    Button {
      isInfoPopoverPresented.toggle()
    } label: {
      Image(systemName: "info.circle")
        .imageScale(.medium)
        .frame(width: 18, height: 18)
    }
    .frame(width: 28, height: 28)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .help("Review data details")
    .accessibilityLabel("Show review data details")
    .popover(isPresented: $isInfoPopoverPresented, arrowEdge: .top) {
      DashboardReviewsProvenancePopover(snapshot: snapshot)
    }
  }
}
