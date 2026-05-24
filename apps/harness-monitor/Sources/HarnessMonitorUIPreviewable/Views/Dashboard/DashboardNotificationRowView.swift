import HarnessMonitorKit
import SwiftUI

struct DashboardNotificationRowView: View {
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

  private func actionVariant(for action: NotificationHistoryAction)
    -> HarnessMonitorAsyncActionButton.Variant
  {
    switch action.kind {
    case .openDecision, .runtimeUndo:
      .prominent
    case .copy, .acknowledgeDecision:
      .bordered
    }
  }
}

struct DashboardNotificationDetailsView: View {
  let details: NotificationHistoryDetails

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if let summary = details.summary {
        Text(summary)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(details.rows.enumerated()), id: \.offset) { _, row in
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

extension NotificationHistoryEntry.Severity {
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

  fileprivate var timelineTone: SessionTimelineTone {
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
      message: "Saved supervisor draft to shared preview fixtures",
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
      message: "A decision needs review before the next automation tick",
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
      message: "The task was restored from Notifications",
      details: NotificationHistoryDetails(
        summary: "Undo restored the task assignment and notes",
        rows: [
          NotificationHistoryDetailRow(label: "Task", value: "task-42"),
          NotificationHistoryDetailRow(label: "Session", value: "sess-alpha"),
        ]
      )
    ),
  ]
}
