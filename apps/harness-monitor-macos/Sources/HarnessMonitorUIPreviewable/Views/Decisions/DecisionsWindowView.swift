import HarnessMonitorKit
import SwiftUI

public struct DecisionsWindowView: View {
  private struct DismissBatchSnapshot: Equatable {
    let ids: [String]
    let count: Int
    let filterSignature: String
    let capturedAt: Date
  }

  private struct ReopenBatchState: Equatable {
    let ids: [String]
    let expiresAt: Date
  }

  private let store: HarnessMonitorStore?

  @State private var selection: String?
  @State private var detailTab: DecisionDetailTab = .context
  @State private var runtime = DecisionsWindowRuntime()
  @State private var sidebarFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )
  @State private var dismissAllVisibleDraft = ""
  @State private var pendingDismissBatch: DismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: ReopenBatchState?

  @AppStorage("harness.decisions.inspector.visible")
  private var inspectorVisible: Bool = true

  public init(store: HarnessMonitorStore? = nil) {
    self.store = store
  }

  private var actionHandler: any DecisionActionHandler {
    store?.supervisorDecisionActionHandler() ?? NullDecisionActionHandler()
  }

  private var selectedDecision: Decision? {
    if let selection {
      return runtime.decisions.first(where: { $0.id == selection }) ?? runtime.decisions.first
    }
    return runtime.decisions.first
  }

  private var openDecisionCount: Int { runtime.decisions.count }

  private var criticalDecisionCount: Int {
    runtime.decisions.reduce(into: 0) { count, decision in
      if decision.severityRaw == DecisionSeverity.critical.rawValue {
        count += 1
      }
    }
  }

  private var infoDecisionIDs: [String] {
    runtime.decisions
      .filter { $0.severityRaw == DecisionSeverity.info.rawValue }
      .map(\.id)
  }

  private var criticalDecisionIDs: [String] {
    runtime.decisions
      .filter { $0.severityRaw == DecisionSeverity.critical.rawValue }
      .map(\.id)
  }

  private var navigationSubtitle: String {
    let openLabel = "\(openDecisionCount) open"
    guard criticalDecisionCount > 0 else {
      return openLabel
    }
    return "\(openLabel) · \(criticalDecisionCount) critical"
  }

  private var inspectorToggleLabel: String {
    inspectorVisible ? "Hide Inspector" : "Show Inspector"
  }

  private var sessionObserver: ObserverSummary? {
    store?.selectedSession?.observer
  }

  private var visibleSnapshot: DecisionsSidebarViewModel.VisibleSnapshot {
    DecisionsSidebarViewModel.visibleSnapshot(
      decisions: runtime.decisions,
      filters: sidebarFilters
    )
  }

  private var visibleOpenDecisionIDs: [String] {
    visibleSnapshot.decisionIDs
  }

  @ViewBuilder private var detailColumn: some View {
    if let selectedDecision {
      DecisionDetailView(
        decision: selectedDecision,
        store: store,
        handler: actionHandler,
        auditEvents: runtime.auditEvents,
        selectedTab: $detailTab,
        observer: sessionObserver,
        primaryActionFocusDecisionID: store?.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store?.supervisorPrimaryActionFocusRequestTick ?? 0
      )
    } else {
      DecisionDetailView(selectedTab: $detailTab, observer: sessionObserver)
    }
  }

  public var body: some View {
    NavigationSplitView {
      DecisionsSidebar(
        decisions: runtime.decisions,
        selection: $selection,
        filters: $sidebarFilters,
        store: store
      )
      .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
    } detail: {
      detailColumn
        .inspector(isPresented: $inspectorVisible) {
          DecisionInspector(
            decision: selectedDecision,
            liveTick: runtime.liveTick
          )
          .inspectorColumnWidth(min: 220, ideal: 250, max: 300)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle("Decisions")
    .navigationSubtitle(navigationSubtitle)
    .toolbar { windowToolbar }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsWindow)
    .task {
      syncSelectionFromStoreIfNeeded()
      await reload()
      syncSelectionFromStoreIfNeeded()
    }
    .task(id: store?.supervisorDecisionRefreshTick ?? -1) {
      await reload()
      syncSelectionFromStoreIfNeeded()
    }
    .onChange(of: store?.supervisorSelectedDecisionID) { _, requestedID in
      guard let requestedID else {
        return
      }
      selection = requestedID
    }
    .onChange(of: selection) { _, newValue in
      store?.supervisorSelectedDecisionID = newValue
    }
    .onChange(of: store?.supervisorObserverFocusTick ?? 0) { _, _ in
      selection = nil
      store?.supervisorSelectedDecisionID = nil
    }
    .onChange(of: store?.supervisorPrimaryActionFocusRequestTick ?? 0) { _, _ in
      guard let requestedID = store?.supervisorPrimaryActionFocusDecisionID else {
        return
      }
      selection = requestedID
      detailTab = .context
    }
    .confirmationDialog(
      "Dismiss all visible decisions",
      isPresented: $showDismissAllVisibleConfirmation,
      titleVisibility: .visible
    ) {
      TextField(
        "Type \(pendingDismissBatch?.count ?? 0) to confirm",
        text: $dismissAllVisibleDraft
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisibleInput)
      Button("Dismiss selected visible") {
        Task { await confirmDismissAllVisible() }
      }
      .disabled(dismissAllVisibleDraft != "\(pendingDismissBatch?.count ?? -1)")
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisibleConfirm)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(dismissConfirmationMessage)
    }
  }

  @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      bulkActionsMenu
      inspectorToggleButton
    }
  }

  private var bulkActionsMenu: some View {
    Menu {
      Button("Dismiss selected") {
        Task { await dismissSelected() }
      }
      .disabled(selection == nil)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissSelected)

      Button("Dismiss all visible") {
        beginDismissAllVisible()
      }
      .disabled(visibleOpenDecisionIDs.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissVisible)

      if let reopenBatch {
        Button("Reopen dismissed batch") {
          Task { await reopenDismissedBatch(reopenBatch) }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkReopenBatch)
      }

      Button("Snooze all critical for 1h") {
        Task { await snoozeAllCritical() }
      }
      .disabled(criticalDecisionIDs.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkSnoozeCritical)

      Button("Dismiss all info") {
        Task { await dismissAllInfo() }
      }
      .disabled(infoDecisionIDs.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissInfo)
    } label: {
      Label("Bulk actions", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .help("Bulk actions")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkActions)
  }

  private var inspectorToggleButton: some View {
    Button {
      inspectorVisible.toggle()
    } label: {
      Label(inspectorToggleLabel, systemImage: "sidebar.right")
    }
    .keyboardShortcut("i", modifiers: [.command, .option])
    .help(inspectorToggleLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionInspectorToggle)
  }

  private func snoozeAllCritical() async {
    let handler = actionHandler
    let oneHour: TimeInterval = 60 * 60
    for id in criticalDecisionIDs {
      await handler.snooze(decisionID: id, duration: oneHour)
    }
  }

  private func syncSelectionFromStoreIfNeeded() {
    guard let requestedID = store?.supervisorSelectedDecisionID else {
      return
    }
    if selection == nil || selection != requestedID {
      selection = requestedID
    }
  }

  private func dismissAllInfo() async {
    let handler = actionHandler
    for id in infoDecisionIDs {
      await handler.dismiss(decisionID: id)
    }
  }

  private func dismissSelected() async {
    guard let selection else {
      return
    }
    await actionHandler.dismiss(decisionID: selection)
  }

  private func beginDismissAllVisible() {
    let ids = visibleOpenDecisionIDs
    guard !ids.isEmpty else {
      return
    }
    pendingDismissBatch = DismissBatchSnapshot(
      ids: ids,
      count: ids.count,
      filterSignature: visibleSnapshot.signature,
      capturedAt: Date()
    )
    dismissAllVisibleDraft = ""
    showDismissAllVisibleConfirmation = true
  }

  private var dismissConfirmationMessage: String {
    guard let snapshot = pendingDismissBatch else {
      return "No visible decisions to dismiss."
    }
    let capturedAt = snapshot.capturedAt.formatted(
      date: .abbreviated,
      time: .standard
    )
    return "Scope: \(snapshot.filterSignature)\nCaptured: \(capturedAt)"
  }

  private func confirmDismissAllVisible() async {
    guard let snapshot = pendingDismissBatch else {
      return
    }
    guard dismissAllVisibleDraft == "\(snapshot.count)" else {
      store?.presentFailureFeedback("Typed count did not match.")
      return
    }
    let currentIDs = visibleOpenDecisionIDs
    guard currentIDs == snapshot.ids, visibleSnapshot.signature == snapshot.filterSignature else {
      store?.presentFailureFeedback("Visible decisions changed. Bulk dismiss aborted.")
      return
    }
    let handler = actionHandler
    for id in snapshot.ids {
      await handler.dismiss(decisionID: id)
    }
    reopenBatch = ReopenBatchState(
      ids: snapshot.ids,
      expiresAt: Date().addingTimeInterval(15)
    )
    pendingDismissBatch = nil
    dismissAllVisibleDraft = ""
  }

  private func reopenDismissedBatch(_ batch: ReopenBatchState) async {
    guard Date() <= batch.expiresAt else {
      store?.presentFailureFeedback("Recovery window expired.")
      reopenBatch = nil
      return
    }
    guard let decisionStore = store?.supervisorDecisionStore else {
      store?.presentFailureFeedback("Cannot reopen dismissed batch: decision store unavailable.")
      return
    }
    for id in batch.ids {
      do {
        guard let decision = try await decisionStore.decision(id: id) else {
          store?.presentFailureFeedback("Cannot reopen \(id): decision missing.")
          continue
        }
        guard decision.statusRaw == "dismissed" else {
          store?.presentFailureFeedback("Cannot reopen \(id): decision state changed.")
          continue
        }
        decision.statusRaw = "open"
        decision.resolutionJSON = nil
      } catch {
        store?.presentFailureFeedback(
          "Failed to reopen \(id): \(error.localizedDescription)"
        )
      }
    }
  }

  private func reload() async {
    await runtime.reload(from: store)

    if let requestedID = store?.supervisorSelectedDecisionID,
      runtime.decisions.contains(where: { $0.id == requestedID })
    {
      selection = requestedID
      return
    }

    if let selection, runtime.decisions.contains(where: { $0.id == selection }) {
      return
    }

    let firstDecisionID = runtime.decisions.first?.id
    selection = firstDecisionID
    store?.supervisorSelectedDecisionID = firstDecisionID
  }
}

#Preview("Decisions Window — empty") {
  DecisionsWindowView()
    .frame(width: 900, height: 640)
}
