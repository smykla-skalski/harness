import Foundation
import HarnessMonitorKit
import SwiftUI

/// Vertically scrolling list of `SupervisorEvent` rows.
///
/// Mirrors the shape of `SessionTimelineList`: `ScrollView` + `LazyVStack` for
/// row diffing, a footer "Load older" button for cursor-driven pagination, and
/// a filtered empty state when the active filters return no events.
public struct AuditTimelineView: View {
  let repository: SupervisorAuditRepository?
  let filters: SupervisorAuditFilters
  @Binding var selectedEvent: SupervisorEventSnapshot?

  @State private var events: [SupervisorEventSnapshot] = []
  @State private var isLoading = false
  @State private var hasOlder = true
  @State private var loadError: String?
  @State private var loadOlderTask: Task<Void, Never>?

  private static let pageSize = 50

  public init(
    repository: SupervisorAuditRepository?,
    filters: SupervisorAuditFilters = .init(),
    selectedEvent: Binding<SupervisorEventSnapshot?>
  ) {
    self.repository = repository
    self.filters = filters
    self._selectedEvent = selectedEvent
  }

  public var body: some View {
    Group {
      if events.isEmpty && isLoading {
        HarnessMonitorSpinner(size: 14)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if events.isEmpty {
        emptyState
      } else {
        timelineScroll
      }
    }
    .task(id: filtersIdentity) {
      loadOlderTask?.cancel()
      loadOlderTask = nil
      await reloadFromTop()
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.auditTimelineList)
  }

  private var timelineScroll: some View {
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(events) { event in
          AuditTimelineRow(
            event: event,
            isSelected: selectedEvent?.id == event.id
          )
          .equatable()
          .id(event.id)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedEvent = event
          }
        }
        if hasOlder {
          loadOlderFooter
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
  }

  private var loadOlderFooter: some View {
    HStack {
      Spacer()
      Button {
        startLoadOlder()
      } label: {
        if isLoading {
          HarnessMonitorSpinner(size: 12)
        } else {
          Text("Load older")
            .scaledFont(.caption.weight(.semibold))
        }
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .disabled(isLoading)
      .accessibilityIdentifier(HarnessMonitorAccessibility.auditTimelineLoadOlder)
      Spacer()
    }
    .padding(HarnessMonitorTheme.spacingMD)
  }

  private var emptyState: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No audit events match your filters.")
        .scaledFont(.body.weight(.semibold))
      if let loadError {
        Text(loadError)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.danger)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(HarnessMonitorTheme.spacingLG)
    .accessibilityIdentifier(HarnessMonitorAccessibility.auditTimelineEmptyState)
  }

  private var filtersIdentity: String {
    let severities = filters.severities.map(\.rawValue).sorted().joined(separator: ",")
    let rules = filters.ruleIDs.sorted().joined(separator: ",")
    let kinds = filters.kinds.map(\.rawValue).sorted().joined(separator: ",")
    let range =
      filters.dateRange.map {
        "\($0.lowerBound.timeIntervalSince1970)-\($0.upperBound.timeIntervalSince1970)"
      }
      ?? ""
    let decision = filters.decisionID?.uuidString ?? ""
    return [
      "search=\(filters.searchText)",
      "sev=\(severities)",
      "rule=\(rules)",
      "kind=\(kinds)",
      "range=\(range)",
      "decision=\(decision)",
    ].joined(separator: ";")
  }

  private func reloadFromTop() async {
    guard let repository else {
      events = []
      hasOlder = false
      isLoading = false
      return
    }
    isLoading = true
    loadError = nil
    defer { isLoading = false }
    do {
      let page = try await repository.fetchEvents(
        filters: filters,
        limit: Self.pageSize,
        before: nil
      )
      events = page
      hasOlder = page.count == Self.pageSize
    } catch {
      if error is CancellationError || Task.isCancelled { return }
      events = []
      hasOlder = false
      loadError = error.localizedDescription
    }
  }

  private func startLoadOlder() {
    guard !isLoading, hasOlder, repository != nil, !events.isEmpty else { return }
    loadOlderTask?.cancel()
    let snapshotFilters = filters
    loadOlderTask = Task { @MainActor in
      await loadOlder(snapshotFilters: snapshotFilters)
    }
  }

  private func loadOlder(snapshotFilters: SupervisorAuditFilters) async {
    guard let repository, !isLoading, hasOlder, let last = events.last else { return }
    guard let lastID = UUID(uuidString: last.id) else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let cursor = SupervisorAuditCursor(createdAt: last.createdAt, id: lastID)
      let page = try await repository.fetchEvents(
        filters: snapshotFilters,
        limit: Self.pageSize,
        before: cursor
      )
      // Skip append if filters changed while we were awaiting; the new
      // .task(id:) has already cancelled this task and reloaded from the top.
      guard snapshotFilters == filters else { return }
      if page.isEmpty {
        hasOlder = false
        return
      }
      let existing = Set(events.map(\.id))
      let appended = page.filter { !existing.contains($0.id) }
      events.append(contentsOf: appended)
      // A fully-deduped page MUST mean we have caught up; otherwise an upstream
      // that re-returns the same head page would keep "Load older" armed
      // forever even after every row is on screen.
      hasOlder = appended.count == Self.pageSize
    } catch {
      if error is CancellationError || Task.isCancelled { return }
      loadError = error.localizedDescription
      hasOlder = false
    }
  }
}
