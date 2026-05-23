import HarnessMonitorKit
import SwiftData
import SwiftUI

/// Settings → Supervisor → Audit pane.
///
/// Composes the retention picker, audit-event filter controls, paginated
/// timeline, payload detail view, and JSONL export button into the live
/// surface that ships with the Supervisor audit feature. Reads the audit
/// repository and SwiftData container off the host `HarnessMonitorStore`;
/// previews and tests can pass `userDefaults` to round-trip the retention
/// picker against an isolated bucket.
public struct SettingsSupervisorAuditPane: View {
  private let store: HarnessMonitorStore?
  @State private var viewModel: SettingsSupervisorAuditViewModel
  @State private var filterState: AuditTimelineFilterState
  @State private var selectedEvent: SupervisorEventSnapshot?
  @Environment(\.supervisorAuditTimelineDispatcher)
  private var supervisorAuditTimelineDispatcher

  public init(
    store: HarnessMonitorStore? = nil,
    userDefaults: UserDefaults = .standard
  ) {
    self.store = store
    _viewModel = State(
      initialValue: SettingsSupervisorAuditViewModel(userDefaults: userDefaults)
    )
    _filterState = State(
      initialValue: AuditTimelineFilterState(userDefaults: userDefaults)
    )
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      retentionForm
      Divider()
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      timelineSection
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsSupervisorPane("audit")
    )
    .onAppear { wireFocusHandler() }
    .onDisappear { clearFocusHandler() }
  }

  // MARK: - Retention

  private var retentionForm: some View {
    Form {
      Section {
        SettingsDurationPickerRow(
          title: "Retention Window",
          presets: Self.retentionPresetsSeconds,
          minSeconds: Self.minimumRetentionSeconds,
          seconds: retentionBinding,
          pickerAccessibilityIdentifier:
            HarnessMonitorAccessibility.settingsSupervisorPane("audit-retention")
        )
        Text(
          """
          Compaction drops supervisor events and resolved decisions older than the retention \
          window. Open decisions are never dropped automatically.
          """
        )
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Retention")
          .harnessNativeFormSectionHeader()
      } footer: {
        Text("Retention applies to both supervisor events and resolved decisions")
          .harnessNativeFormSectionFooter()
      }
    }
    .settingsDetailFormStyle()
  }

  // MARK: - Timeline

  private var timelineSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      timelineHeader
      AuditTimelineFilterControls(
        state: filterState,
        ruleIDs: Self.builtInRuleIDs,
        kinds: SupervisorEvent.Kind.allCases
      )
      timelineBody
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var timelineHeader: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Timeline")
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      AuditTimelineExportButton(
        filters: filterState.filters,
        modelContainer: modelContainer
      )
    }
  }

  private var timelineBody: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
      AuditTimelineView(
        repository: repository,
        filters: filterState.filters,
        selectedEvent: $selectedEvent
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      detailColumn
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var detailColumn: some View {
    if let selectedEvent {
      AuditTimelineDetailView(event: selectedEvent)
    } else {
      detailPlaceholder
    }
  }

  private var detailPlaceholder: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("Select an event")
        .scaledFont(.body.weight(.semibold))
      Text("Pick a row to inspect its payload")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.03))
    }
    .accessibilityIdentifier("harness.audit.detail.placeholder")
  }

  // MARK: - Store-derived sources

  private var repository: SupervisorAuditRepository? {
    store?.supervisorAuditRepository
  }

  private var modelContainer: ModelContainer? {
    store?.modelContext?.container
  }

  // MARK: - Focus handler

  /// Wire the focus dispatcher's payload (rule + decision ids) through to the
  /// filter state so the cross-link from `DecisionAuditTrailTab` and the
  /// `Cmd+Shift+A` menu command pre-apply their query. The dispatcher
  /// replays any query received before this pane mounted.
  private func wireFocusHandler() {
    supervisorAuditTimelineDispatcher?.registerFilterHandler { [filterState] query in
      Self.apply(query: query, to: filterState)
    }
  }

  private func clearFocusHandler() {
    supervisorAuditTimelineDispatcher?.clearFilterHandler()
  }

  /// Mirror the query payload onto the filter state. A query with both fields
  /// nil (`SupervisorAuditTimelineQuery()`) is a "just open the pane" signal
  /// and leaves existing filters untouched so `Cmd+Shift+A` does not surprise
  /// the operator by clearing chips. `ruleID` becomes a single active rule
  /// chip; `decisionID` parses as `UUID` since the audit predicate keys
  /// decision references that way. A malformed `decisionID` is dropped
  /// rather than reset so the rule chip alone can still narrow results.
  static func apply(
    query: SupervisorAuditTimelineQuery,
    to filterState: AuditTimelineFilterState
  ) {
    let trimmedRuleID = query.ruleID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDecisionID = query.decisionID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasRuleID = (trimmedRuleID?.isEmpty == false)
    let hasDecisionID = (trimmedDecisionID?.isEmpty == false)
    guard hasRuleID || hasDecisionID else { return }
    if let trimmedRuleID, !trimmedRuleID.isEmpty {
      filterState.filters.ruleIDs = [trimmedRuleID]
    }
    if let trimmedDecisionID, !trimmedDecisionID.isEmpty,
      let uuid = UUID(uuidString: trimmedDecisionID)
    {
      filterState.filters.decisionID = uuid
    }
  }

  // MARK: - Bridging

  /// Bridges the view model's `TimeInterval` retention to the `UInt64` seconds the
  /// duration picker requires. Negative or non-finite values are clamped to the
  /// minimum retention before being committed back to the view model.
  private var retentionBinding: Binding<UInt64> {
    Binding(
      get: { Self.unsignedSeconds(from: viewModel.retentionSeconds) },
      set: { newValue in
        viewModel.retentionSeconds = TimeInterval(newValue)
      }
    )
  }

  private static func unsignedSeconds(from interval: TimeInterval) -> UInt64 {
    guard interval.isFinite, interval > 0 else { return minimumRetentionSeconds }
    return UInt64(interval.rounded())
  }

  // MARK: - Presets

  static let minimumRetentionSeconds: UInt64 = 24 * 60 * 60
  static let retentionPresetsSeconds: [UInt64] = [
    24 * 60 * 60,
    7 * 24 * 60 * 60,
    14 * 24 * 60 * 60,
    30 * 24 * 60 * 60,
    90 * 24 * 60 * 60,
  ]

  /// Built-in supervisor rule IDs surfaced as filter options. Sourced from the
  /// shared catalog so adding a rule there flows into the chip without a
  /// settings-pane edit.
  static let builtInRuleIDs: [String] =
    HarnessMonitorSupervisorRuleCatalog
    .makeRules()
    .map(\.id)
    .sorted()
}
