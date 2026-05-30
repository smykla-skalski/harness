import HarnessMonitorKit
import SwiftUI

struct DashboardNotificationsRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private var rows: [DashboardNotificationTimelineRow] {
    DashboardNotificationTimelineRow.rows(
      for: dashboardUI.notificationHistory,
      configuration: dateTimeConfiguration
    )
  }

  private var summary: DashboardNotificationSummary {
    DashboardNotificationSummary(entries: dashboardUI.notificationHistory)
  }

  var body: some View {
    _ = HarnessMonitorPerfTrace.countBodyEval("DashboardNotificationsRouteView")
    HarnessMonitorColumnScrollView(
      horizontalPadding: 0,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardNotificationsScrollView,
      scrollSurfaceLabel: "Notifications"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        DashboardNotificationsSummaryCard(summary: summary)
          .padding(.horizontal, 24)

        if rows.isEmpty {
          emptyState
            .padding(.horizontal, 24)
        } else {
          DashboardNotificationsTimeline(
            rows: rows,
            store: store
          )
          .padding(.horizontal, 24)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardNotificationsRoot)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No notifications yet", systemImage: "bell.slash")
    } description: {
      Text("In-app toasts and Notification Center deliveries will appear here")
    }
    .frame(maxWidth: .infinity, minHeight: 320)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardNotificationsEmptyState)
  }
}

private struct DashboardNotificationSummary: Equatable {
  let totalCount: Int
  let activeCount: Int
  let toastCount: Int
  let systemCount: Int

  init(entries: [NotificationHistoryEntry]) {
    totalCount = entries.count
    activeCount = entries.count {
      switch $0.status {
      case .active, .delivered:
        true
      case .dismissed, .evicted, .opened, .acknowledged, .acted, .undone:
        false
      }
    }
    toastCount = entries.count { $0.source == .toast }
    systemCount = totalCount - toastCount
  }

  var subtitle: String {
    guard totalCount > 0 else {
      return "In-app toasts and Notification Center deliveries are collected here"
    }
    if activeCount > 0 {
      return "\(totalCount) entries captured so far, \(activeCount) still active"
    }
    return "\(totalCount) entries captured so far. No active notifications right now"
  }
}

private struct DashboardNotificationsSummaryCard: View {
  let summary: DashboardNotificationSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
        Image(systemName: "bell.badge.fill")
          .font(.system(size: 28, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.accent)
          .frame(width: 40, height: 40)

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text("Notifications")
            .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
          Text(summary.subtitle)
            .scaledFont(.callout)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
      }

      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        SessionTimelineBadge(
          label: "\(summary.totalCount) total",
          tint: HarnessMonitorTheme.accent,
          style: .prominent
        )
        SessionTimelineBadge(
          label: "\(summary.activeCount) active",
          tint: HarnessMonitorTheme.success,
          style: .quiet
        )
        SessionTimelineBadge(
          label: "\(summary.toastCount) toasts",
          tint: HarnessMonitorTheme.secondaryInk,
          style: .quiet
        )
        SessionTimelineBadge(
          label: "\(summary.systemCount) notifications",
          tint: HarnessMonitorTheme.caution,
          style: .quiet
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
    .background(SessionTimelineCardBackground(tint: HarnessMonitorTheme.accent))
  }
}

private struct DashboardNotificationsTimeline: View {
  let rows: [DashboardNotificationTimelineRow]
  let store: HarnessMonitorStore

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(rows) { row in
        DashboardNotificationNodeCluster(row: row, store: store)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(alignment: .topLeading) {
      if !rows.isEmpty {
        SessionTimelineRailBackground()
      }
    }
  }
}

struct DashboardNotificationTimelineRow: Identifiable, Equatable {
  let entry: NotificationHistoryEntry
  let dayDividerLabel: String?
  let timeLabel: String
  let accessibilityTimestampLabel: String
  let accessibilityLabel: String

  var id: String { entry.id }

  @MainActor
  static func rows(
    for entries: [NotificationHistoryEntry],
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> [Self] {
    var previousDay: Date?
    return entries.map { entry in
      let day = timelineDayStart(for: entry.recordedAt, configuration: configuration)
      let label =
        previousDay != nil && previousDay != day
        ? formatTimelineDayDivider(entry.recordedAt, configuration: configuration)
        : nil
      previousDay = day
      let timestampLabel = formatTimelineTimestamp(entry.recordedAt, configuration: configuration)
      return Self(
        entry: entry,
        dayDividerLabel: label,
        timeLabel: formatTimelineTime(entry.recordedAt, configuration: configuration),
        accessibilityTimestampLabel: timestampLabel,
        accessibilityLabel: accessibilityLabel(for: entry, timestampLabel: timestampLabel)
      )
    }
  }

  @MainActor
  private static func accessibilityLabel(
    for entry: NotificationHistoryEntry,
    timestampLabel: String
  ) -> String {
    var parts = [
      entry.source.label,
      timestampLabel,
      entry.severity.label,
      entry.statusText,
    ]
    if let title = entry.title {
      parts.append(title)
    }
    if let subtitle = entry.subtitle {
      parts.append(subtitle)
    }
    parts.append(entry.message)
    if entry.repeatCount > 1 {
      parts.append("Repeated \(entry.repeatCount) times")
    }
    if !entry.actions.isEmpty {
      parts.append("\(entry.actions.count) actions available")
    }
    return parts.joined(separator: ", ")
  }
}

private struct DashboardNotificationNodeCluster: View {
  let row: DashboardNotificationTimelineRow
  let store: HarnessMonitorStore

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      if let label = row.dayDividerLabel {
        SessionTimelineDayDivider(label: label)
      }
      DashboardNotificationRowView(row: row, store: store)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
