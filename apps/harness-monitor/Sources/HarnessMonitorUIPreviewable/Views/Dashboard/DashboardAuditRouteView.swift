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
  let history: GlobalWindowNavigationHistory?
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @AppStorage(DashboardAuditContentDetailWidthRestoration.storageKey)
  private var contentDetailWidth = DashboardAuditContentDetailWidthRestoration.defaultWidth
  @State private var filters = DashboardAuditFilters()
  @State private var selectedEventID: String?
  @State private var visibleEventLimit = DashboardAuditPaging.pageSize
  @State private var keepsNavigationLimitOnFilterChange = false
  @State private var routedTimelineEvent: HarnessMonitorAuditEvent?
  @State private var navigationScrollTarget: DashboardAuditTimelineScrollTarget?
  @State private var copyDispatcher = DashboardAuditCopyDispatcher()
  @FocusState private var focusedFilterField: DashboardAuditFilterField?

  private var events: [HarnessMonitorAuditEvent] {
    guard let routedTimelineEvent else { return dashboardUI.auditEvents }
    return HarnessMonitorAuditEvent.merged(dashboardUI.auditEvents + [routedTimelineEvent])
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
          focusedField: $focusedFilterField,
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
      .harnessFocusedSceneValue(
        \.dashboardAuditCopyCommand,
        DashboardAuditCopyFocus(
          canCopy: selectedEvent != nil && focusedFilterField == nil,
          dispatcher: copyDispatcher
        )
      )
      .onAppear {
        configureCopyDispatcher()
      }
      .task {
        configureCopyDispatcher()
        await refreshAudit(limit: visibleEventLimit)
        selectFirstEventIfNeeded()
        _ = applyPendingNavigationIfNeeded(reportsMissing: false)
      }
      .onChange(of: filters) { _, _ in
        if keepsNavigationLimitOnFilterChange {
          keepsNavigationLimitOnFilterChange = false
          selectFirstEventIfNeeded()
        } else {
          resetVisibleEventLimit()
          selectedEventID = nil
          selectFirstEventIfNeeded()
        }
        configureCopyDispatcher()
      }
      .onChange(of: filteredEvents) { _, _ in
        selectFirstEventIfNeeded()
        _ = applyPendingNavigationIfNeeded(reportsMissing: false)
        configureCopyDispatcher()
      }
      .onChange(of: selectedEventID) { _, _ in
        configureCopyDispatcher()
      }
      .task(id: history?.pendingDashboardAuditRestoreRequest?.requestID) {
        guard history?.pendingDashboardAuditRestoreRequest != nil else { return }
        if applyPendingNavigationIfNeeded(reportsMissing: false) { return }
        await refreshAudit(limit: DashboardAuditPaging.navigationLimit)
        _ = applyPendingNavigationIfNeeded(reportsMissing: true)
      }
    }
  }

  private var timelinePane: some View {
    DashboardAuditTimelinePane(
      events: visibleEvents,
      selectedEventID: $selectedEventID,
      configuration: dateTimeConfiguration,
      hasMoreEvents: hasMoreEvents,
      loadMoreEvents: loadMoreEvents,
      copyDispatcher: copyDispatcher,
      navigationScrollTarget: navigationScrollTarget
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
    if let selectedEventID,
      let requiredLimit = DashboardAuditSelectionVisibility.requiredLimit(
        selectedEventID: selectedEventID,
        orderedEventIDs: filteredEvents.map(\.id),
        currentLimit: visibleEventLimit
      )
    {
      visibleEventLimit = requiredLimit
      return
    }
    selectedEventID = visibleEvents.first?.id ?? filteredEvents[0].id
  }

  @discardableResult
  private func applyPendingNavigationIfNeeded(reportsMissing: Bool) -> Bool {
    guard let history, let request = history.pendingDashboardAuditRestoreRequest else {
      return false
    }
    guard let target = request.target else {
      resetRoutedNavigation()
      history.finishDashboardAuditRestoreRequest(request.requestID)
      return true
    }
    if let routedEvent = target.routedEvent {
      routedTimelineEvent = routedEvent
    }
    guard
      let event = target.routedEvent
        ?? events.first(where: { $0.id == target.eventID })
    else {
      guard reportsMissing else { return false }
      history.finishDashboardAuditRestoreRequest(request.requestID)
      store.presentFailureFeedback("The requested activity is unavailable")
      return true
    }
    var navigationFilters = DashboardAuditFilters()
    navigationFilters.datePreset = .all
    if let index = events.firstIndex(where: { $0.id == event.id }) {
      let centeredLimit = min(events.count, index + 1 + DashboardAuditPaging.pageSize / 2)
      visibleEventLimit = max(visibleEventLimit, centeredLimit)
    }
    if filters != navigationFilters {
      keepsNavigationLimitOnFilterChange = true
      filters = navigationFilters
    }
    selectedEventID = event.id
    navigationScrollTarget = DashboardAuditTimelineScrollTarget(
      eventID: event.id,
      requestID: request.requestID
    )
    history.finishDashboardAuditRestoreRequest(request.requestID)
    return true
  }

  private func resetRoutedNavigation() {
    routedTimelineEvent = nil
    navigationScrollTarget = nil
    keepsNavigationLimitOnFilterChange = false
    visibleEventLimit = DashboardAuditPaging.pageSize
    filters = DashboardAuditFilters()
    selectedEventID = nil
    selectFirstEventIfNeeded()
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
    do {
      let lines = try visibleEvents.map { event in
        try event.clipboardJSONString(prettyPrinted: false)
      }
      writeClipboardText(
        lines.joined(separator: "\n"),
        failureMessage: "Could not copy visible audit rows to the clipboard."
      )
    } catch {
      store.presentFailureFeedback(
        "Could not copy visible audit rows: \(error.localizedDescription)"
      )
    }
  }

  private func configureCopyDispatcher() {
    copyDispatcher.copySelectedEventHandler = {
      copySelectedEvent()
    }
    copyDispatcher.copyEventHandler = { event in
      copyEvent(event)
    }
  }

  private func copySelectedEvent() {
    do {
      guard let text = try selectedEvent?.clipboardJSONString() else { return }
      writeClipboardText(
        text,
        failureMessage: "Could not copy the selected audit event to the clipboard."
      )
    } catch {
      store.presentFailureFeedback("Could not copy audit event: \(error.localizedDescription)")
    }
  }

  private func copyEvent(_ event: HarnessMonitorAuditEvent) {
    do {
      let text = try event.clipboardJSONString()
      writeClipboardText(
        text,
        failureMessage: "Could not copy audit event to the clipboard."
      )
    } catch {
      store.presentFailureFeedback("Could not copy audit event: \(error.localizedDescription)")
    }
  }

  private func writeClipboardText(_ text: String, failureMessage: String) {
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
      store.presentFailureFeedback(failureMessage)
      return
    }
  }
}

private enum DashboardAuditPaging {
  static let pageSize = 40
  static let navigationLimit = 1_000
}

@MainActor
public final class DashboardAuditCopyDispatcher {
  var copySelectedEventHandler: (() -> Void)?
  var copyEventHandler: ((HarnessMonitorAuditEvent) -> Void)?

  public init() {}

  public func copySelectedEvent() {
    copySelectedEventHandler?()
  }

  public func copy(event: HarnessMonitorAuditEvent) {
    copyEventHandler?(event)
  }
}

public struct DashboardAuditCopyFocus: Equatable {
  public let canCopy: Bool
  public let dispatcher: DashboardAuditCopyDispatcher

  public init(
    canCopy: Bool,
    dispatcher: DashboardAuditCopyDispatcher
  ) {
    self.canCopy = canCopy
    self.dispatcher = dispatcher
  }

  @MainActor
  public func copy() {
    dispatcher.copySelectedEvent()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canCopy == rhs.canCopy
      && lhs.dispatcher === rhs.dispatcher
  }
}

extension FocusedValues {
  @Entry public var dashboardAuditCopyCommand: DashboardAuditCopyFocus?
}
