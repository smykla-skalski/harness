import HarnessMonitorKit
import SwiftUI

/// Date range preset surfaced in the audit timeline date chip.
public enum AuditTimelineDateRangePreset: String, CaseIterable, Identifiable, Sendable {
  case today
  case last7Days
  case last30Days

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .today:
      "Today"
    case .last7Days:
      "Last 7 days"
    case .last30Days:
      "Last 30 days"
    }
  }

  /// Resolve a `SupervisorAuditDateRange` ending at `reference`.
  public func range(reference: Date = Date(), calendar: Calendar = .current) -> SupervisorAuditDateRange {
    let endOfDay = calendar.endOfDay(for: reference) ?? reference
    switch self {
    case .today:
      let start = calendar.startOfDay(for: reference)
      return SupervisorAuditDateRange(start: start, end: endOfDay)
    case .last7Days:
      let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: reference))
        ?? reference
      return SupervisorAuditDateRange(start: start, end: endOfDay)
    case .last30Days:
      let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: reference))
        ?? reference
      return SupervisorAuditDateRange(start: start, end: endOfDay)
    }
  }
}

extension Calendar {
  fileprivate func endOfDay(for date: Date) -> Date? {
    var components = DateComponents()
    components.day = 1
    components.second = -1
    return self.date(byAdding: components, to: startOfDay(for: date))
  }
}

/// Filter chrome for the Supervisor Audit Timeline.
///
/// Mirrors the chip + menu structure of `SessionTimelineFilterControls`. The
/// host owns rule and kind option lists because `SupervisorEvent.kind` is a
/// free-form string in storage and the rule catalog is per-policy.
public struct AuditTimelineFilterControls: View {
  @Bindable var state: AuditTimelineFilterState
  let ruleIDs: [String]
  let kinds: [String]

  public init(
    state: AuditTimelineFilterState,
    ruleIDs: [String],
    kinds: [String] = []
  ) {
    self.state = state
    self.ruleIDs = ruleIDs
    self.kinds = kinds
  }

  public var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      ruleChip
      kindChip
      severityChip
      dateRangeChip
      searchField
      if state.isAnyActive {
        clearButton
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("supervisor.audit.filterBar")
  }

  // MARK: - Rule chip

  private var ruleChip: some View {
    Menu {
      Section("Rule") {
        Button("All rules") {
          state.clearRuleIDs()
        }
        Divider()
        ForEach(ruleIDs, id: \.self) { ruleID in
          Button {
            state.toggleRuleID(ruleID)
          } label: {
            if state.filters.ruleIDs.contains(ruleID) {
              Label(ruleID, systemImage: "checkmark")
            } else {
              Text(ruleID)
            }
          }
        }
      }
    } label: {
      chipLabel(
        title: "Rule",
        badge: state.filters.ruleIDs.count,
        systemImage: "ruler"
      )
    }
    .harnessFilterChipButtonStyle(isSelected: !state.filters.ruleIDs.isEmpty)
    .harnessNativeFormControl()
    .accessibilityIdentifier("supervisor.audit.filter.rule")
  }

  // MARK: - Kind chip (multi-select Apply / Clear)

  @State private var kindDraft: Set<String> = []

  private var kindChip: some View {
    Menu {
      Section("Kind") {
        ForEach(kinds, id: \.self) { kind in
          Button {
            toggleKindDraft(kind)
          } label: {
            if kindDraft.contains(kind) {
              Label(kind, systemImage: "checkmark")
            } else {
              Text(kind)
            }
          }
        }
        Divider()
        Button("Apply") {
          state.filters.kinds = kindDraft
        }
        .disabled(kindDraft == state.filters.kinds)
        Button("Clear") {
          kindDraft = []
          state.clearKinds()
        }
        .disabled(kindDraft.isEmpty && state.filters.kinds.isEmpty)
      }
    } label: {
      chipLabel(
        title: "Kind",
        badge: state.filters.kinds.count,
        systemImage: "tag"
      )
    }
    .harnessFilterChipButtonStyle(isSelected: !state.filters.kinds.isEmpty)
    .harnessNativeFormControl()
    .accessibilityIdentifier("supervisor.audit.filter.kind")
    .onAppear {
      kindDraft = state.filters.kinds
    }
    .onChange(of: state.filters.kinds) { _, newValue in
      kindDraft = newValue
    }
  }

  private func toggleKindDraft(_ kind: String) {
    if kindDraft.contains(kind) {
      kindDraft.remove(kind)
    } else {
      kindDraft.insert(kind)
    }
  }

  // MARK: - Severity chip (multi-select)

  private var severityChip: some View {
    Menu {
      Section("Severity") {
        Button("All severities") {
          state.clearSeverities()
        }
        Divider()
        ForEach(DecisionSeverity.allCases, id: \.self) { severity in
          Button {
            state.toggleSeverity(severity)
          } label: {
            if state.filters.severities.contains(severity) {
              Label(severityLabel(severity), systemImage: "checkmark")
            } else {
              Text(severityLabel(severity))
            }
          }
        }
      }
    } label: {
      chipLabel(
        title: "Severity",
        badge: state.filters.severities.count,
        systemImage: "exclamationmark.triangle"
      )
    }
    .harnessFilterChipButtonStyle(isSelected: !state.filters.severities.isEmpty)
    .harnessNativeFormControl()
    .accessibilityIdentifier("supervisor.audit.filter.severity")
  }

  private func severityLabel(_ severity: DecisionSeverity) -> String {
    switch severity {
    case .info: "Info"
    case .warn: "Warning"
    case .needsUser: "Needs user"
    case .critical: "Critical"
    }
  }

  // MARK: - Date range chip

  @State private var showsCustomDateSheet = false
  @State private var customStart = Date()
  @State private var customEnd = Date()

  private var dateRangeChip: some View {
    Menu {
      Section("Date range") {
        Button("Any date") {
          state.setDateRange(nil)
        }
        Divider()
        ForEach(AuditTimelineDateRangePreset.allCases) { preset in
          Button(preset.label) {
            state.setDateRange(preset.range())
          }
        }
        Divider()
        Button("Custom…") {
          if let current = state.filters.dateRange {
            customStart = current.start
            customEnd = current.end
          } else {
            customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
            customEnd = Date()
          }
          showsCustomDateSheet = true
        }
      }
    } label: {
      chipLabel(
        title: dateRangeLabel,
        badge: state.filters.dateRange == nil ? 0 : 1,
        systemImage: "calendar"
      )
    }
    .harnessFilterChipButtonStyle(isSelected: state.filters.dateRange != nil)
    .harnessNativeFormControl()
    .accessibilityIdentifier("supervisor.audit.filter.dateRange")
    .popover(isPresented: $showsCustomDateSheet, arrowEdge: .top) {
      customDateRangePopover
    }
  }

  private var dateRangeLabel: String {
    state.filters.dateRange == nil ? "Date" : "Date range"
  }

  private var customDateRangePopover: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Custom date range")
        .scaledFont(.headline)
      DatePicker("Start", selection: $customStart, displayedComponents: [.date])
      DatePicker("End", selection: $customEnd, in: customStart..., displayedComponents: [.date])
      HStack {
        Spacer()
        Button("Cancel") { showsCustomDateSheet = false }
        Button("Apply") {
          state.setDateRange(
            SupervisorAuditDateRange(start: customStart, end: customEnd)
          )
          showsCustomDateSheet = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(minWidth: 280)
  }

  // MARK: - Search field

  private var searchField: some View {
    TextField(
      "Search audit events",
      text: Binding(
        get: { state.filters.searchText },
        set: { state.setSearchText($0) }
      )
    )
    .textFieldStyle(.roundedBorder)
    .frame(maxWidth: 220)
    .accessibilityIdentifier("supervisor.audit.filter.search")
  }

  // MARK: - Clear

  private var clearButton: some View {
    Button("Clear") {
      state.clear()
    }
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .harnessNativeFormControl()
    .accessibilityIdentifier("supervisor.audit.filter.clear")
  }

  // MARK: - Shared chip label

  private func chipLabel(title: String, badge: Int, systemImage: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .imageScale(.small)
      Text(title)
        .lineLimit(1)
      if badge > 0 {
        Text("\(badge)")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .scaledFont(.caption.weight(.semibold))
  }
}
