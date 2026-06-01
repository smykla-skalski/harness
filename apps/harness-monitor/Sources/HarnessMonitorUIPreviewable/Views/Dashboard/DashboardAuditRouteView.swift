import AppKit
import HarnessMonitorKit
import SwiftUI

enum DashboardAuditContentDetailWidthRestoration {
  static let storageKey = "dashboard.audit.content-detail-width"
  static let defaultWidth = SessionContentDetailSplitLayout.defaultContentWidth
}

struct DashboardAuditRouteView: View {
  let store: HarnessMonitorStore
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @AppStorage(DashboardAuditContentDetailWidthRestoration.storageKey)
  private var contentDetailWidth = DashboardAuditContentDetailWidthRestoration.defaultWidth
  @State private var filters = DashboardAuditFilters()
  @State private var selectedEventID: String?
  @State private var visibleEventLimit = DashboardAuditPaging.pageSize

  private var events: [HarnessMonitorAuditEvent] {
    dashboardUI.auditEvents
  }

  private var filteredEvents: [HarnessMonitorAuditEvent] {
    filters.apply(to: events)
  }

  private var visibleEvents: [HarnessMonitorAuditEvent] {
    Array(filteredEvents.prefix(visibleEventLimit))
  }

  private var hasMoreEvents: Bool {
    filteredEvents.count > visibleEventLimit || dashboardUI.auditHasOlder
  }

  private var selectedEvent: HarnessMonitorAuditEvent? {
    guard let selectedEventID else {
      return visibleEvents.first
    }
    return filteredEvents.first { $0.id == selectedEventID } ?? visibleEvents.first
  }

  private var notificationEntry: NotificationHistoryEntry? {
    guard let entryID = selectedEvent?.notificationEntryID else { return nil }
    return dashboardUI.notificationHistory.first { $0.id == entryID }
  }

  var body: some View {
    ViewBodySignposter.trace(Self.self, "DashboardAuditRouteView") {
      VStack(spacing: 0) {
        DashboardAuditSummaryStrip(
          events: filteredEvents,
          notificationHistory: dashboardUI.notificationHistory
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)

        DashboardAuditFilterBar(
          filters: $filters,
          events: events,
          exportVisibleRows: copyVisibleRows
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        Divider()

        SessionContentDetailSplitView(
          contentWidth: $contentDetailWidth,
          commitContentWidth: { contentDetailWidth = $0 },
          dividerAccessibilityIdentifier:
            HarnessMonitorAccessibility.dashboardAuditDetailDivider,
          showsDividerLine: false,
          content: { timelinePane },
          detail: { detailPane }
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAuditRoot)
      .task {
        await refreshAudit(limit: visibleEventLimit)
        selectFirstEventIfNeeded()
      }
      .onChange(of: filters) { _, _ in
        resetVisibleEventLimit()
        selectedEventID = nil
        selectFirstEventIfNeeded()
      }
      .onChange(of: filteredEvents) { _, _ in
        selectFirstEventIfNeeded()
      }
    }
  }

  private var timelinePane: some View {
    DashboardAuditTimelinePane(
      events: visibleEvents,
      selectedEventID: $selectedEventID,
      configuration: dateTimeConfiguration,
      hasMoreEvents: hasMoreEvents,
      loadMoreEvents: loadMoreEvents
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var detailPane: some View {
    DashboardAuditDetailPane(
      event: selectedEvent,
      notificationEntry: notificationEntry,
      store: store,
      configuration: dateTimeConfiguration
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func selectFirstEventIfNeeded() {
    guard !filteredEvents.isEmpty else {
      selectedEventID = nil
      return
    }
    if selectedEventID == nil || !filteredEvents.contains(where: { $0.id == selectedEventID }) {
      selectedEventID = visibleEvents.first?.id ?? filteredEvents[0].id
    }
  }

  private func resetVisibleEventLimit() {
    visibleEventLimit = DashboardAuditPaging.pageSize
  }

  private func loadMoreEvents() {
    let nextLimit = visibleEventLimit + DashboardAuditPaging.pageSize
    visibleEventLimit = nextLimit
    Task {
      await refreshAudit(limit: nextLimit)
      selectFirstEventIfNeeded()
    }
  }

  private func refreshAudit(limit: Int) async {
    await store.refreshApplicationAudit(limit: limit)
  }

  private func copyVisibleRows() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let lines = visibleEvents.compactMap { event -> String? in
      guard let data = try? encoder.encode(event) else { return nil }
      return String(data: data, encoding: .utf8)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }
}

private enum DashboardAuditPaging {
  static let pageSize = 40
}

private struct DashboardAuditFilters: Equatable {
  var source = DashboardAuditFilterConstants.allValue
  var category = DashboardAuditFilterConstants.allValue
  var outcome = DashboardAuditFilterConstants.allValue
  var severity = DashboardAuditFilterConstants.allValue
  var datePreset = DashboardAuditDatePreset.thirtyDays
  var actionKey = ""
  var subject = ""
  var searchText = ""

  func apply(to events: [HarnessMonitorAuditEvent]) -> [HarnessMonitorAuditEvent] {
    let cutoff = datePreset.cutoffDate
    let actionKeyFilter = normalized(actionKey)
    let subjectFilter = normalized(subject)
    let searchFilter = normalized(searchText)
    return events.filter { event in
      matches(source, event.source)
        && matches(category, event.category)
        && matches(outcome, event.outcome)
        && matches(severity, event.severity)
        && cutoff.map { event.recordedAt >= $0 } ?? true
        && matchesText(event.actionKey, actionKeyFilter)
        && matchesText(event.subject, subjectFilter)
        && matchesSearch(event, searchFilter)
    }
    .sorted(by: HarnessMonitorAuditEvent.auditEventSort)
  }

  private func matches(_ filter: String, _ value: String) -> Bool {
    filter == DashboardAuditFilterConstants.allValue || filter == value
  }

  private func matchesText(_ value: String?, _ filter: String?) -> Bool {
    guard let filter else { return true }
    return value?.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private func matchesSearch(_ event: HarnessMonitorAuditEvent, _ filter: String?) -> Bool {
    guard let filter else { return true }
    let haystacks = [
      event.title,
      event.summary,
      event.subject,
      event.actor,
      event.actionKey,
      event.legacyMessage,
    ]
    return haystacks.contains { value in
      value?.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private enum DashboardAuditFilterConstants {
  static let allValue = "All"
}

private enum DashboardAuditDatePreset: String, CaseIterable, Identifiable {
  case oneDay
  case sevenDays
  case fourteenDays
  case thirtyDays
  case ninetyDays
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .oneDay: "1d"
    case .sevenDays: "7d"
    case .fourteenDays: "14d"
    case .thirtyDays: "30d"
    case .ninetyDays: "90d"
    case .all: "All"
    }
  }

  var cutoffDate: Date? {
    let days: Int
    switch self {
    case .oneDay: days = 1
    case .sevenDays: days = 7
    case .fourteenDays: days = 14
    case .thirtyDays: days = 30
    case .ninetyDays: days = 90
    case .all: return nil
    }
    return Calendar.current.date(byAdding: .day, value: -days, to: .now)
  }
}

private struct DashboardAuditSummaryStrip: View {
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

private struct DashboardAuditFilterBar: View {
  @Binding var filters: DashboardAuditFilters
  let events: [HarnessMonitorAuditEvent]
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
        .frame(width: 150)

      TextField("Subject", text: $filters.subject)
        .textFieldStyle(.roundedBorder)
        .frame(width: 150)

      TextField("Search", text: $filters.searchText)
        .textFieldStyle(.roundedBorder)
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

private struct DashboardAuditTimelinePane: View {
  let events: [HarnessMonitorAuditEvent]
  @Binding var selectedEventID: String?
  let configuration: HarnessMonitorDateTimeConfiguration
  let hasMoreEvents: Bool
  let loadMoreEvents: () -> Void

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
              isSelected: row.event.id == selectedEventID
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
      .buttonStyle(.plain)
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
    .buttonStyle(.plain)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardAuditRow(row.event.id))
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

private struct DashboardAuditDetailPane: View {
  let event: HarnessMonitorAuditEvent?
  let notificationEntry: NotificationHistoryEntry?
  let store: HarnessMonitorStore
  let configuration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    Group {
      if let event {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header(event)
            InspectorFactGrid(facts: facts(for: event))
            payloadSection(event)
            legacySection(event)
            notificationActions
            relatedLinks(event)
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ContentUnavailableView {
          Label("Select an audit event", systemImage: "sidebar.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func header(_ event: HarnessMonitorAuditEvent) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: event.auditSourceIcon)
        .font(.title2)
        .foregroundStyle(event.auditTint)
        .frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 6) {
        Text(event.title)
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        Text(event.summary)
          .scaledFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Button {
        copyEvent(event)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .help("Copy audit event")
    }
  }

  private func facts(for event: HarnessMonitorAuditEvent) -> [InspectorFact] {
    var facts = [
      InspectorFact(title: "Source", value: event.source.auditDisplayLabel),
      InspectorFact(title: "Category", value: event.category.auditDisplayLabel),
      InspectorFact(title: "Kind", value: event.kind),
      InspectorFact(title: "Severity", value: event.severity.auditDisplayLabel),
      InspectorFact(title: "Outcome", value: event.outcome.auditDisplayLabel),
      InspectorFact(
        title: "Recorded",
        value: formatTimelineTimestamp(event.recordedAt, configuration: configuration)
      ),
    ]
    if let subject = event.subject {
      facts.append(InspectorFact(title: "Subject", value: subject))
    }
    if let actor = event.actor {
      facts.append(InspectorFact(title: "Actor", value: actor))
    }
    if let correlationID = event.correlationID {
      facts.append(InspectorFact(title: "Correlation", value: correlationID))
    }
    if let actionKey = event.actionKey {
      facts.append(InspectorFact(title: "Action", value: actionKey))
    }
    facts.append(InspectorFact(title: "Event ID", value: event.id))
    return facts
  }

  @ViewBuilder
  private func payloadSection(_ event: HarnessMonitorAuditEvent) -> some View {
    if let payload = event.payloadJSONString() {
      DashboardAuditJSONPayloadBlock(title: "Payload", payload: payload)
    }
  }

  @ViewBuilder
  private func legacySection(_ event: HarnessMonitorAuditEvent) -> some View {
    if let legacyMessage = event.legacyMessage {
      DashboardAuditTextBlock(title: "Legacy Message", text: legacyMessage)
    }
  }

  @ViewBuilder private var notificationActions: some View {
    if let notificationEntry, !notificationEntry.actions.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Actions")
          .scaledFont(.headline)
        HStack(spacing: 8) {
          ForEach(notificationEntry.actions) { action in
            Button {
              Task {
                _ = await store.performNotificationHistoryAction(
                  entryID: notificationEntry.id,
                  action: action
                )
              }
            } label: {
              Label(action.title, systemImage: action.systemImage)
            }
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.dashboardNotificationAction(
                notificationEntry.id,
                actionID: action.id
              )
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private func relatedLinks(_ event: HarnessMonitorAuditEvent) -> some View {
    if !event.relatedURLs.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Related")
          .scaledFont(.headline)
        ForEach(event.relatedURLs, id: \.self) { rawURL in
          Button {
            if let url = URL(string: rawURL) {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Label(rawURL, systemImage: "link")
              .lineLimit(1)
          }
          .buttonStyle(.link)
        }
      }
    }
  }

  private func copyEvent(_ event: HarnessMonitorAuditEvent) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard
      let data = try? encoder.encode(event),
      let text = String(data: data, encoding: .utf8)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct DashboardAuditJSONPayloadBlock: View {
  let title: String
  let payload: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.headline)
      HarnessMonitorJSONCodeBlock(rawJSON: payload)
    }
  }
}

private struct DashboardAuditTextBlock: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.headline)
      ScrollView(.horizontal) {
        Text(text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}

extension HarnessMonitorAuditEvent {
  fileprivate var auditSourceIcon: String {
    switch source {
    case "notifications":
      "bell.badge"
    case "supervisor":
      "checkmark.diamond"
    case "github":
      "shippingbox.circle"
    case "daemon":
      "terminal"
    case "taskBoard":
      "checklist"
    case "policy":
      "point.3.connected.trianglepath.dotted"
    default:
      "list.bullet.rectangle"
    }
  }

  fileprivate var auditTint: Color {
    severity.auditSeverityTint ?? outcome.auditOutcomeTint ?? HarnessMonitorTheme.accent
  }

  fileprivate var outcomeTint: Color {
    outcome.auditOutcomeTint ?? severity.auditSeverityTint ?? HarnessMonitorTheme.accent
  }

  fileprivate var showsGitHubEdgeMark: Bool {
    source.caseInsensitiveCompare("github") == .orderedSame
      || category.auditTokenContains("github")
      || kind.auditTokenContains("github")
      || actionKey?.auditTokenContains("github") == true
      || actionKey?.lowercased().hasPrefix("reviews.") == true
      || relatedURLs.contains { $0.auditTokenContains("github.com") }
  }
}

extension String {
  fileprivate var auditSeverityTint: Color? {
    switch lowercased() {
    case "error", "failure", "failed", "fatal":
      HarnessMonitorTheme.danger
    case "warning", "attention":
      HarnessMonitorTheme.caution
    case "success":
      HarnessMonitorTheme.success
    case "debug":
      HarnessMonitorTheme.secondaryInk
    default:
      nil
    }
  }

  fileprivate var auditOutcomeTint: Color? {
    switch lowercased() {
    case "success", "completed", "complete", "approved", "merged", "applied", "updated",
      "dismissed":
      HarnessMonitorTheme.success
    case "waiting", "pending", "running", "in_progress", "in-progress", "deferred", "queued",
      "started":
      HarnessMonitorTheme.caution
    case "failure", "failed", "error", "blocked", "denied", "rejected", "cancelled",
      "canceled":
      HarnessMonitorTheme.danger
    case "warning", "attention":
      HarnessMonitorTheme.caution
    default:
      nil
    }
  }

  fileprivate func auditTokenContains(_ token: String) -> Bool {
    range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  fileprivate var auditDisplayLabel: String {
    replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }
}
