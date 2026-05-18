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
      Text("In-app toasts and Notification Center deliveries will appear here.")
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
      return "In-app toasts and Notification Center deliveries are collected here."
    }
    if activeCount > 0 {
      return "\(totalCount) entries captured so far, \(activeCount) still active."
    }
    return "\(totalCount) entries captured so far. No active notifications right now."
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

private struct DashboardNotificationTimelineRow: Identifiable, Equatable {
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

private struct DashboardNotificationRowView: View {
  let row: DashboardNotificationTimelineRow
  let store: HarnessMonitorStore
  @Environment(\.fontScale)
  private var fontScale

  private var entry: NotificationHistoryEntry { row.entry }

  private var cardTint: Color { entry.severity.timelineTone.color }

  private var statusTint: Color {
    switch entry.status {
    case .active:
      return HarnessMonitorTheme.accent
    case .delivered:
      return HarnessMonitorTheme.secondaryInk
    case .dismissed:
      return HarnessMonitorTheme.secondaryInk
    case .evicted:
      return HarnessMonitorTheme.caution
    case .opened:
      return HarnessMonitorTheme.accent
    case .acknowledged:
      return HarnessMonitorTheme.success
    case .acted:
      return HarnessMonitorTheme.caution
    case .undone:
      return HarnessMonitorTheme.accent
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(verbatim: row.timeLabel)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .frame(width: SessionTimelineLayout.timeColumnWidth, alignment: .leading)
        .accessibilityHidden(true)

      SessionTimelineDot(tint: cardTint)
        .padding(.top, 3)

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        header
        if let subtitle = entry.subtitle {
          Text(subtitle)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        if shouldShowMessageBody {
          Text(entry.message)
            .scaledFont(.callout)
            .foregroundStyle(HarnessMonitorTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let details = entry.details {
          DashboardNotificationDetailsView(details: details)
        }
        badges
        if !entry.actions.isEmpty {
          actions
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(
        EdgeInsets(
          top: HarnessMonitorTheme.spacingSM * max(1, fontScale),
          leading: HarnessMonitorTheme.cardPadding,
          bottom: HarnessMonitorTheme.spacingSM * max(1, fontScale),
          trailing: HarnessMonitorTheme.cardPadding
        )
      )
      .background(SessionTimelineCardBackground(tint: cardTint))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      if let title = entry.title {
        Button("Copy title", systemImage: "doc.on.doc") {
          HarnessMonitorClipboard.copy(title)
        }
      }
      Button("Copy message", systemImage: "text.quote") {
        HarnessMonitorClipboard.copy(entry.message)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardNotificationRow(entry.id))
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Text(entry.title ?? entry.message)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      if entry.repeatCount > 1 {
        SessionTimelineBadge(
          label: "\(entry.repeatCount)x",
          tint: cardTint,
          style: .quiet
        )
      }
    }
  }

  private var badges: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      SessionTimelineBadge(
        label: entry.source.label,
        tint: HarnessMonitorTheme.secondaryInk,
        style: .quiet
      )
      SessionTimelineBadge(
        label: entry.severity.label,
        tint: cardTint,
        style: .quiet
      )
      SessionTimelineBadge(
        label: entry.statusText,
        tint: statusTint,
        style: .quiet
      )
    }
  }

  private var actions: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingSM,
      lineSpacing: HarnessMonitorTheme.spacingSM
    ) {
      ForEach(entry.actions) { action in
        HarnessMonitorAsyncActionButton(
          title: action.title,
          tint: actionTint(for: action),
          variant: actionVariant(for: action),
          isLoading: false,
          accessibilityIdentifier: HarnessMonitorAccessibility.dashboardNotificationAction(
            entry.id,
            actionID: action.id
          )
        ) {
          _ = await store.performNotificationHistoryAction(entryID: entry.id, action: action)
        }
      }
    }
  }

  private var shouldShowMessageBody: Bool {
    entry.title != nil || entry.subtitle != nil
  }

  private func actionTint(for action: NotificationHistoryAction) -> Color? {
    switch action.kind {
    case .copy:
      HarnessMonitorTheme.secondaryInk
    case .openDecision:
      HarnessMonitorTheme.accent
    case .acknowledgeDecision:
      HarnessMonitorTheme.success
    case .runtimeUndo:
      HarnessMonitorTheme.accent
    }
  }

  private func actionVariant(for action: NotificationHistoryAction) -> HarnessMonitorAsyncActionButton.Variant {
    switch action.kind {
    case .openDecision, .runtimeUndo:
      .prominent
    case .copy, .acknowledgeDecision:
      .bordered
    }
  }
}

private struct DashboardNotificationDetailsView: View {
  let details: NotificationHistoryDetails

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if let summary = details.summary {
        Text(summary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(details.rows, id: \.self) { row in
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(row.label)
            .scaledFont(.caption.monospaced().weight(.medium))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(row.value)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let command = details.command {
        Text(command)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textSelection(.enabled)
          .padding(.horizontal, HarnessMonitorTheme.spacingSM)
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
              .fill(HarnessMonitorTheme.ink.opacity(0.04))
          )
      }
    }
  }
}

private extension NotificationHistoryEntry.Severity {
  var label: String {
    switch self {
    case .info:
      return "Info"
    case .success:
      return "Success"
    case .warning:
      return "Warning"
    case .failure:
      return "Failure"
    case .attention:
      return "Attention"
    }
  }

  var timelineTone: SessionTimelineTone {
    switch self {
    case .info, .attention:
      return .info
    case .success:
      return .success
    case .warning:
      return .warning
    case .failure:
      return .critical
    }
  }
}

#Preview("Dashboard Notifications Route") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)
  store.notificationHistoryEntries = DashboardNotificationsRoutePreview.entries
  return DashboardNotificationsRouteView(
    store: store,
    dashboardUI: store.contentUI.dashboard
  )
  .frame(width: 980, height: 760)
}

private enum DashboardNotificationsRoutePreview {
  static let entries: [NotificationHistoryEntry] = [
    NotificationHistoryEntry(
      id: "toast-success",
      recordedAt: .now.addingTimeInterval(-60),
      updatedAt: .now.addingTimeInterval(-60),
      source: .toast,
      severity: .success,
      status: .dismissed,
      statusText: "Dismissed automatically",
      title: "Draft saved",
      message: "Saved supervisor draft to shared preview fixtures.",
      actions: [
        NotificationHistoryAction(
          id: "copy",
          title: "Copy path",
          systemImage: "doc.on.doc",
          kind: .copy(text: "/tmp/harness/draft.json"),
          successAnnouncement: "Draft path copied"
        )
      ]
    ),
    NotificationHistoryEntry(
      id: "system-open",
      recordedAt: .now.addingTimeInterval(-320),
      updatedAt: .now.addingTimeInterval(-280),
      source: .supervisorDecision,
      severity: .attention,
      status: .opened,
      statusText: "Opened in Notification Center",
      title: "Harness Monitor",
      subtitle: "Supervisor attention required",
      message: "A decision needs review before the next automation tick.",
      actions: [
        NotificationHistoryAction(
          id: "open",
          title: "Open",
          systemImage: "arrow.up.forward.app",
          kind: .openDecision(decisionID: "decision-preview")
        ),
        NotificationHistoryAction(
          id: "ack",
          title: "Acknowledge",
          systemImage: "checkmark.circle",
          kind: .acknowledgeDecision(decisionID: "decision-preview")
        ),
      ],
      requestIdentifier: "decision-preview-request",
      decisionID: "decision-preview"
    ),
    NotificationHistoryEntry(
      id: "toast-undo",
      recordedAt: .now.addingTimeInterval(-5400),
      updatedAt: .now.addingTimeInterval(-5380),
      source: .toast,
      severity: .attention,
      status: .undone,
      statusText: "Undo completed",
      title: "Task removed",
      message: "The task was restored from Notifications.",
      details: NotificationHistoryDetails(
        summary: "Undo restored the task assignment and notes.",
        rows: [
          NotificationHistoryDetailRow(label: "Task", value: "task-42"),
          NotificationHistoryDetailRow(label: "Session", value: "sess-alpha"),
        ]
      )
    ),
  ]
}
