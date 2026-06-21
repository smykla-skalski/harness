import HarnessMonitorKit
import SwiftUI

struct DashboardAuditSummaryStrip: View {
  let events: [HarnessMonitorAuditEvent]
  let notificationHistory: [NotificationHistoryEntry]

  private var warningsAndFailures: Int {
    events.count { event in
      event.severity == "warning"
        || event.severity == "error"
        || event.severity == "failure"
        || event.outcome == "failure"
    }
  }

  private var githubActions: Int {
    events.count { event in event.showsGitHubEdgeMark }
  }

  private var activeNotifications: Int {
    notificationHistory.count { entry in
      entry.status == .active || entry.status == .delivered
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      DashboardAuditMetric(title: "Events", value: String(events.count), icon: "list.bullet")
      DashboardAuditMetric(
        title: "Warnings",
        value: String(warningsAndFailures),
        icon: "exclamationmark.triangle"
      )
      DashboardAuditMetric(title: "GitHub", value: String(githubActions), icon: "shippingbox")
      DashboardAuditMetric(
        title: "Notifications",
        value: String(activeNotifications),
        icon: "bell.badge"
      )
      Spacer(minLength: 0)
    }
  }
}

private struct DashboardAuditMetric: View {
  let title: String
  let value: String
  let icon: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .frame(width: 18)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .monospacedDigit()
      Text(title)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct DashboardAuditFilterBar: View {
  @Binding var filters: DashboardAuditFilters
  let events: [HarnessMonitorAuditEvent]
  let focusedField: FocusState<DashboardAuditFilterField?>.Binding
  let exportVisibleRows: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Picker("Source", selection: $filters.source) {
        filterOptions(\.source)
      }
      .frame(width: 135)

      Picker("Category", selection: $filters.category) {
        filterOptions(\.category)
      }
      .frame(width: 145)

      Picker("Outcome", selection: $filters.outcome) {
        filterOptions(\.outcome)
      }
      .frame(width: 135)

      Picker("Severity", selection: $filters.severity) {
        filterOptions(\.severity)
      }
      .frame(width: 135)

      Picker("Date", selection: $filters.datePreset) {
        ForEach(DashboardAuditDatePreset.allCases) { preset in
          Text(preset.title).tag(preset)
        }
      }
      .fixedSize(horizontal: true, vertical: false)

      TextField("Action key", text: $filters.actionKey)
        .textFieldStyle(.roundedBorder)
        .focused(focusedField, equals: .actionKey)
        .frame(width: 150)

      TextField("Subject", text: $filters.subject)
        .textFieldStyle(.roundedBorder)
        .focused(focusedField, equals: .subject)
        .frame(width: 150)

      TextField("Search", text: $filters.searchText)
        .textFieldStyle(.roundedBorder)
        .focused(focusedField, equals: .searchText)
        .frame(minWidth: 180)

      Button {
        exportVisibleRows()
      } label: {
        Image(systemName: "square.and.arrow.up")
      }
      .help("Copy visible audit rows")
    }
  }

  @ViewBuilder
  private func filterOptions(
    _ keyPath: KeyPath<HarnessMonitorAuditEvent, String>
  ) -> some View {
    Text(DashboardAuditFilterConstants.allValue).tag(DashboardAuditFilterConstants.allValue)
    ForEach(optionValues(keyPath), id: \.self) { value in
      Text(value.auditDisplayLabel).tag(value)
    }
  }

  private func optionValues(_ keyPath: KeyPath<HarnessMonitorAuditEvent, String>) -> [String] {
    Array(Set(events.map { $0[keyPath: keyPath] })).sorted()
  }
}

struct DashboardAuditTimelinePane: View {
  let events: [HarnessMonitorAuditEvent]
  @Binding var selectedEventID: String?
  let configuration: HarnessMonitorDateTimeConfiguration
  let hasMoreEvents: Bool
  let loadMoreEvents: () -> Void
  let copyDispatcher: DashboardAuditCopyDispatcher

  private var rows: [DashboardAuditTimelineRow] {
    DashboardAuditTimelineRow.rows(for: events, configuration: configuration)
  }

  var body: some View {
    if rows.isEmpty {
      VStack(spacing: 12) {
        ContentUnavailableView {
          Label("No audit events", systemImage: "list.bullet.rectangle.portrait")
        }
        if hasMoreEvents {
          DashboardAuditLoadMoreButton(action: loadMoreEvents)
            .padding(.horizontal, 12)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAuditEmptyState)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            if let dayDividerLabel = row.dayDividerLabel {
              DashboardAuditDayDivider(label: dayDividerLabel)
            }
            DashboardAuditTimelineRowView(
              row: row,
              isSelected: row.event.id == selectedEventID,
              copyDispatcher: copyDispatcher
            ) {
              selectedEventID = row.event.id
            }
          }
          if hasMoreEvents {
            DashboardAuditLoadMoreButton(action: loadMoreEvents)
          }
        }
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.18), value: rows.map(\.id))
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAuditScrollView)
    }
  }
}

private struct DashboardAuditTimelineRow: Identifiable, Equatable {
  let event: HarnessMonitorAuditEvent
  let dayDividerLabel: String?
  let timeLabel: String
  let accessibilityLabel: String

  var id: String { event.id }

  @MainActor
  static func rows(
    for events: [HarnessMonitorAuditEvent],
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> [Self] {
    var previousDay: Date?
    let currentDay = timelineDayStart(for: .now, configuration: configuration)
    return events.map { event in
      let day = timelineDayStart(for: event.recordedAt, configuration: configuration)
      let showsDivider = previousDay == nil ? day != currentDay : previousDay != day
      let label =
        showsDivider
        ? formatTimelineDayDivider(event.recordedAt, configuration: configuration)
        : nil
      previousDay = day
      let timestamp = formatTimelineTimestamp(event.recordedAt, configuration: configuration)
      return Self(
        event: event,
        dayDividerLabel: label,
        timeLabel: formatTimelineTime(event.recordedAt, configuration: configuration),
        accessibilityLabel: [
          event.source,
          timestamp,
          event.severity,
          event.outcome,
          event.title,
          event.subject,
        ].compactMap(\.self).joined(separator: ", ")
      )
    }
  }
}

private struct DashboardAuditDayDivider: View {
  let label: String

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      line
      Text(label)
        .scaledFont(.caption.monospaced().weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      line
    }
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .center)
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .accessibilityLabel("Audit date \(label)")
  }

  private var line: some View {
    Rectangle()
      .fill(HarnessMonitorTheme.controlBorder.opacity(0.42))
      .frame(height: 1)
  }
}

private struct DashboardAuditLoadMoreButton: View {
  let action: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      line
      Button(action: action) {
        HStack(spacing: 6) {
          Image(systemName: "ellipsis")
          Text("Load more events")
        }
        .scaledFont(.caption.monospaced().weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      }
      .harnessPlainButtonStyle()
      .help("Load more audit events")
      line
    }
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  private var line: some View {
    Rectangle()
      .fill(HarnessMonitorTheme.controlBorder.opacity(0.42))
      .frame(height: 1)
  }
}

private enum DashboardAuditTimelineRowLayout {
  static let sourceIconSize: CGFloat = 22
  static let githubMarkSize: CGFloat = 14
}

private struct DashboardAuditTimelineRowView: View {
  let row: DashboardAuditTimelineRow
  let isSelected: Bool
  let copyDispatcher: DashboardAuditCopyDispatcher
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: row.event.auditSourceIcon)
          .frame(
            width: DashboardAuditTimelineRowLayout.sourceIconSize,
            height: DashboardAuditTimelineRowLayout.sourceIconSize
          )
          .foregroundStyle(row.event.auditTint)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          titleRow
          subtitleRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 8)
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityAction(named: Text("Copy Event")) {
      copyEvent(row.event)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAuditRow(row.event.id))
    .contextMenu {
      Button("Copy Event") {
        copyEvent(row.event)
      }
    }
  }

  private var titleRow: some View {
    HStack(alignment: .center, spacing: 8) {
      Text(row.event.title)
        .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
        .lineLimit(1)
      Spacer(minLength: 8)
      if row.event.showsGitHubEdgeMark {
        gitHubEdgeMark
      }
      DashboardAuditOutcomeBadge(event: row.event)
    }
  }

  private var subtitleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(spacing: 8) {
        Text(row.event.source.auditDisplayLabel)
        if let subject = row.event.subject {
          Text(subject)
        }
      }
      .scaledFont(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      Spacer(minLength: 8)
      Text(row.timeLabel)
        .scaledFont(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private var gitHubEdgeMark: some View {
    ProviderBrandSymbolView(
      symbol: .github,
      colorMode: .automaticContrast,
      size: DashboardAuditTimelineRowLayout.githubMarkSize
    )
    .opacity(0.86)
    .accessibilityHidden(true)
  }

  private func copyEvent(_ event: HarnessMonitorAuditEvent) {
    copyDispatcher.copy(event: event)
  }
}

private struct DashboardAuditOutcomeBadge: View {
  let event: HarnessMonitorAuditEvent

  var body: some View {
    Text(event.outcome.auditDisplayLabel)
      .scaledFont(.caption2)
      .foregroundStyle(event.outcomeTint)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        event.outcomeTint.opacity(0.14),
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
  }
}
