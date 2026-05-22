import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsRepositorySectionHeader: View {
  let repository: String
  let itemCount: Int
  let busyPullRequestCount: Int
  let isCollapsed: Bool
  let scheduler: DashboardReviewsScheduler
  let onToggleCollapse: () -> Void
  let onRetryRepository: () -> Void

  var body: some View {
    let isSyncing = scheduler.repositoriesInFlight.contains(repository)
    let state = scheduler.states[repository]
    let lastSyncedAt = state?.lastSyncedAt
    let errorMessage = state?.lastErrorMessage
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Button(action: onToggleCollapse) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(width: 12, alignment: .center)
          Text(repository)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.borderless)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      repositorySyncStatus(
        isSyncing: isSyncing,
        lastSyncedAt: lastSyncedAt,
        errorMessage: errorMessage
      )
      if busyPullRequestCount > 0 {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ProgressView()
            .controlSize(.small)
          DashboardReviewStatusPill(
            label: "\(busyPullRequestCount) working",
            tint: HarnessMonitorTheme.accent
          )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(busyAccessibilityLabel)
      }
      if let errorMessage, !isSyncing {
        Button(action: onRetryRepository) {
          Image(systemName: "arrow.clockwise.circle")
            .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .help("Retry \(repository): \(errorMessage)")
        .accessibilityLabel("Retry \(repository)")
        .accessibilityHint(errorMessage)
      }
      DashboardReviewsRepositoryHeaderPill(
        title: String(itemCount),
        accessibilityLabel: itemCountAccessibilityLabel
      )
    }
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }

  @ViewBuilder
  private func repositorySyncStatus(
    isSyncing: Bool,
    lastSyncedAt: Date?,
    errorMessage: String?
  ) -> some View {
    if isSyncing {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Syncing \(repository)")
    } else if let errorMessage {
      DashboardReviewsRepositoryHeaderPill(
        title: "Error",
        systemImage: "exclamationmark.triangle",
        accessibilityLabel: "Last sync failed: \(errorMessage)"
      )
      .help(errorMessage)
    } else if let lastSyncedAt {
      let relative = reviewsRelativeFormatter.localizedString(
        for: lastSyncedAt, relativeTo: .now)
      DashboardReviewsRepositoryHeaderPill(
        title: relative,
        systemImage: "arrow.triangle.2.circlepath",
        accessibilityLabel: "Last synced \(relative)"
      )
    }
  }

  private var itemCountAccessibilityLabel: String {
    itemCount == 1 ? "1 review" : "\(itemCount) reviews"
  }

  private var busyAccessibilityLabel: String {
    busyPullRequestCount == 1
      ? "1 pull request updating"
      : "\(busyPullRequestCount) pull requests updating"
  }
}

@MainActor
private struct DashboardReviewsRepositoryHeaderPill: View {
  let title: String
  let systemImage: String?
  let accessibilityLabel: String

  @ScaledMetric(relativeTo: .caption)
  private var height = 22.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 8.0

  init(title: String, systemImage: String? = nil, accessibilityLabel: String) {
    self.title = title
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(verbatim: title)
        .monospacedDigit()
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, horizontalPadding)
    .frame(height: height, alignment: .center)
    .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
    .accessibilityLabel(accessibilityLabel)
  }
}
