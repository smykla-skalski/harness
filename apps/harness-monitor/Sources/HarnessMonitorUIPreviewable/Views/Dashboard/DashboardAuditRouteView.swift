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

struct DashboardAuditFilters: Equatable {
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

enum DashboardAuditFilterConstants {
  static let allValue = "All"
}

enum DashboardAuditDatePreset: String, CaseIterable, Identifiable {
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
