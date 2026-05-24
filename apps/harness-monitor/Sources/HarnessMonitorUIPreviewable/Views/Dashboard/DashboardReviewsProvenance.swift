import Foundation
import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsProvenanceSnapshot: Equatable {
  private static let fractionalDateParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let regularDateParser: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

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

  /// Data-source tint follows the colour-role table on
  /// `HarnessMonitorTheme`: `.accent` for the healthy live feed (the
  /// "feed is alive" affordance), `.caution` for in-progress sync or
  /// stale-but-live state, `.danger` for offline or broken data. Green
  /// is intentionally reserved for content states so users do not
  /// conflate "data is live" with "this PR is good".
  var sourceTint: Color {
    switch overallHealth {
    case .success:
      HarnessMonitorTheme.accent
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
    var title = "\(itemCount) PRs"
    if fetchedDate != nil || !fetchedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      title += " · \(fetchedAgeTitle)"
    }
    if syncingRepositoryCount > 0 {
      title += " · syncing \(syncingRepositoryCount)"
    }
    if !failedRepositories.isEmpty {
      title += " · \(failedRepositories.count) failed"
    }
    if !staleRepositories.isEmpty {
      title += " · \(staleRepositories.count) stale"
    }
    return title
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
      lines.append(
        "Fetched snapshot older than \(harnessMonitorDuration(freshnessCeilingSeconds)) "
          + "(\(thresholdSource))"
      )
    }
    if !staleRepositories.isEmpty {
      lines.append("Repository sync stale for \(repositoryList(staleRepositories))")
    }
    return lines
  }

  private var thresholdSource: String {
    cacheMaxAgeSeconds >= perRepositoryIntervalSeconds
      ? "cache TTL"
      : "per-repo sync interval"
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
    return fractionalDateParser.date(from: value) ?? regularDateParser.date(from: value)
  }

  func repositoryList(_ repositories: [String]) -> String {
    var visible = ""
    for (index, repository) in repositories.prefix(3).enumerated() {
      if index > 0 {
        visible += ", "
      }
      visible += repository
    }
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
    .harnessMCPButton(
      HarnessMonitorAccessibility.dashboardReviewsRefreshButton,
      label: "Refresh review data",
      hint: "Reload the Reviews list from the daemon",
      pressAction: onRefresh
    )
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsInfoButton)
    .popover(isPresented: $isInfoPopoverPresented, arrowEdge: .top) {
      DashboardReviewsProvenancePopover(snapshot: snapshot)
    }
  }
}
