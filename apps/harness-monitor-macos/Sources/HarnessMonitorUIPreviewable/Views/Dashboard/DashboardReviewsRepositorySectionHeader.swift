import HarnessMonitorKit
import SwiftUI

/// Visual derivation for the repository section header.
///
/// Pure value type: given the scheduler-derived inputs, returns the exact
/// status-cluster variant the header should render. Lets the visual-state
/// matrix be unit-tested without touching SwiftUI.
public enum DashboardReviewsRepositorySectionHeaderStatus: Equatable {
  case syncing
  case error(message: String)
  case lastSynced(date: Date)
  case neverSynced

  public static func derive(
    isSyncing: Bool,
    lastSyncedAt: Date?,
    errorMessage: String?
  ) -> Self {
    if isSyncing {
      return .syncing
    }
    if let errorMessage {
      return .error(message: errorMessage)
    }
    if let lastSyncedAt {
      return .lastSynced(date: lastSyncedAt)
    }
    return .neverSynced
  }
}

/// Whether the retry control should be visible for the current state.
///
/// Retry stays visible while a repository is syncing because the previous
/// failure is still the most recent outcome the user has any reason to act on;
/// it's only marked disabled so the click is inert until the in-flight tick
/// completes.
public func dashboardReviewsRepositorySectionHeaderShouldShowRetry(
  errorMessage: String?
) -> Bool {
  errorMessage != nil
}

public func dashboardReviewsRepositorySectionHeaderRetryIsEnabled(
  isSyncing: Bool
) -> Bool {
  !isSyncing
}

/// Accessibility label for the busy-progress indicator. Carries the
/// `X working` count that the old trailing pill used to render visually.
public func dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(
  busyPullRequestCount: Int
) -> String {
  busyPullRequestCount == 1
    ? "1 pull request updating"
    : "\(busyPullRequestCount) pull requests updating"
}

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
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: isSyncing,
      lastSyncedAt: lastSyncedAt,
      errorMessage: errorMessage
    )
    Button(action: onToggleCollapse) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(width: 12, alignment: .center)
          Text(repository)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        syncStatusCluster(status: status, isSyncing: isSyncing, errorMessage: errorMessage)
        Divider()
          .frame(height: 12)
        DashboardReviewsRepositoryHeaderPill(
          title: String(itemCount),
          accessibilityLabel: itemCountAccessibilityLabel
        )
        .help("\(itemCount) pull requests")
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }

  @ViewBuilder
  private func syncStatusCluster(
    status: DashboardReviewsRepositorySectionHeaderStatus,
    isSyncing: Bool,
    errorMessage: String?
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      statusView(for: status)
      if busyPullRequestCount > 0 {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(
            dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(
              busyPullRequestCount: busyPullRequestCount
            )
          )
      }
      if dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: errorMessage) {
        retryButton(errorMessage: errorMessage ?? "", isSyncing: isSyncing)
      }
    }
  }

  @ViewBuilder
  private func statusView(
    for status: DashboardReviewsRepositorySectionHeaderStatus
  ) -> some View {
    switch status {
    case .syncing:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Syncing \(repository)")
    case .error(let message):
      DashboardReviewsRepositoryHeaderPill(
        title: "Error",
        systemImage: "exclamationmark.triangle",
        accessibilityLabel: "Last sync failed: \(message)"
      )
      .help(message)
    case .lastSynced(let date):
      let relative = reviewsRelativeFormatter.localizedString(
        for: date, relativeTo: .now)
      DashboardReviewsRepositoryHeaderPill(
        title: relative,
        systemImage: "arrow.triangle.2.circlepath",
        accessibilityLabel: "Last synced \(relative)"
      )
    case .neverSynced:
      DashboardReviewsRepositoryHeaderPill(
        title: "Never synced",
        accessibilityLabel: "Never synced"
      )
    }
  }

  private func retryButton(errorMessage: String, isSyncing: Bool) -> some View {
    let enabled = dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: isSyncing)
    return Button(action: onRetryRepository) {
      Image(systemName: "arrow.clockwise.circle")
        .imageScale(.medium)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help("Retry \(repository): \(errorMessage)")
    .accessibilityLabel("Retry \(repository)")
    .accessibilityHint(errorMessage)
  }

  private var itemCountAccessibilityLabel: String {
    itemCount == 1 ? "1 review" : "\(itemCount) reviews"
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
