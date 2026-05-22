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

  let source: Source
  let fetchedAt: String
  let fetchedDate: Date?
  let fetchedSnapshotIsStale: Bool
  let cacheMaxAgeSeconds: UInt64
  let perRepositoryIntervalSeconds: UInt64
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
    fetchedSnapshotIsStale =
      fetchedDate.map {
        now.timeIntervalSince($0) > TimeInterval(cacheMaxAgeSeconds)
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
      "Live daemon"
    case .cache:
      "Persisted cache"
    case .offlineCache:
      "Offline cache"
    case .lastLiveSnapshot:
      "Last live snapshot"
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
    case .offlineCache:
      "wifi.slash"
    case .lastLiveSnapshot:
      "clock.badge.exclamationmark"
    case .empty:
      "shippingbox"
    }
  }

  var sourceTint: Color {
    switch source {
    case .live where !hasFreshnessRisk:
      HarnessMonitorTheme.success
    case .empty:
      HarnessMonitorTheme.secondaryInk
    case .cache, .offlineCache, .lastLiveSnapshot, .live:
      HarnessMonitorTheme.caution
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
    "cache max \(durationTitle(cacheMaxAgeSeconds))"
  }

  var repositoryPolicyTitle: String {
    "repo sync \(durationTitle(perRepositoryIntervalSeconds))"
  }

  var detailTitle: String {
    var parts = [sourceTitle, "\(itemCount) PRs"]
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

  var warningTitle: String? {
    if case .offlineCache(let reason) = source {
      return "Daemon offline: \(reason)"
    }
    if case .lastLiveSnapshot(let reason) = source {
      return "Daemon offline: \(reason)"
    }
    if !failedRepositories.isEmpty {
      return "Repository sync failed for \(repositoryList(failedRepositories))"
    }
    if fetchedSnapshotIsStale {
      return "Fetched snapshot exceeds \(durationTitle(cacheMaxAgeSeconds))"
    }
    if !staleRepositories.isEmpty {
      return "Repository sync stale for \(repositoryList(staleRepositories))"
    }
    return nil
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

  private func durationTitle(_ seconds: UInt64) -> String {
    if seconds < 60 {
      return "\(seconds)s"
    }
    if seconds < 3_600 {
      return "\(seconds / 60)m"
    }
    return "\(seconds / 3_600)h"
  }

  private func repositoryList(_ repositories: [String]) -> String {
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        Label(snapshot.sourceTitle, systemImage: snapshot.sourceSystemImage)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(snapshot.sourceTint)
        Text(snapshot.detailTitle)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .imageScale(.medium)
            .frame(width: 18, height: 18)
        }
        .harnessPlainButtonStyle()
        .help("Refresh review data")
        .accessibilityLabel("Refresh review data")
      }

      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        DashboardReviewStatusPill(
          label: snapshot.fetchedAtTitle,
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "clock"
        )
        DashboardReviewStatusPill(
          label: snapshot.cachePolicyTitle,
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "archivebox"
        )
        DashboardReviewStatusPill(
          label: snapshot.repositoryPolicyTitle,
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "arrow.triangle.2.circlepath"
        )
        if snapshot.repositoryCount > 0 {
          DashboardReviewStatusPill(
            label: "\(snapshot.repositoryCount) repos",
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "tray.full"
          )
        }
      }

      if let warningTitle = snapshot.warningTitle {
        Label(warningTitle, systemImage: "exclamationmark.triangle")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .harnessFloatingControlGlass(cornerRadius: 8, tint: snapshot.sourceTint)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsProvenance)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Review data provenance")
    .accessibilityValue(snapshot.detailTitle)
  }
}

struct DashboardReviewProvenanceMiniBar: View {
  let snapshot: DashboardReviewsProvenanceSnapshot

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Label(snapshot.sourceTitle, systemImage: snapshot.sourceSystemImage)
        .foregroundStyle(snapshot.sourceTint)
      Text(snapshot.fetchedAgeTitle)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let warningTitle = snapshot.warningTitle {
        Text(warningTitle)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .lineLimit(1)
      }
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Review data source")
    .accessibilityValue(snapshot.detailTitle)
  }
}
