import HarnessMonitorKit
import SwiftUI

public struct WorkspaceDecisionDeskPreviewView: View {
  private let store: HarnessMonitorStore?

  @State private var selection: String?
  @State private var detailTab: DecisionDetailTab = .context
  @State private var runtime = WorkspaceDecisionRuntime()
  @State private var sidebarFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )
  @State private var dismissAllVisibleDraft = ""
  @State private var pendingDismissBatch: WorkspaceDecisionDismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: WorkspaceDecisionReopenBatchState?

  @State private var inspectorVisible = false

  public init(store: HarnessMonitorStore? = nil) {
    self.store = store
  }

  private var actionHandler: any DecisionActionHandler {
    store?.supervisorDecisionActionHandler() ?? NullDecisionActionHandler()
  }

  private var decisionWorkspaceScope: DecisionWorkspaceScope {
    DecisionWorkspaceScope(
      decisions: runtime.decisions,
      filters: sidebarFilters,
      selectedDecisionID: selection
    )
  }

  private var selectedDecision: Decision? {
    decisionWorkspaceScope.selectedDecision
  }

  private var openDecisionCount: Int { decisionWorkspaceScope.totalCount }

  private var criticalDecisionCount: Int {
    decisionWorkspaceScope.criticalCount
  }

  private var infoDecisionIDs: [String] {
    decisionWorkspaceScope.visibleInfoDecisionIDs
  }

  private var criticalDecisionIDs: [String] {
    decisionWorkspaceScope.visibleCriticalDecisionIDs
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
    decisionWorkspaceScope.visibleSnapshot
  }

  private var visibleOpenDecisionIDs: [String] {
    decisionWorkspaceScope.visibleDecisionIDs
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
        decisionScope: decisionWorkspaceScope,
        primaryActionFocusDecisionID: store?.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store?.supervisorPrimaryActionFocusRequestTick ?? 0
      )
    } else {
      DecisionDetailView(
        selectedTab: $detailTab,
        observer: sessionObserver,
        decisionScope: decisionWorkspaceScope
      )
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
          .inspectorColumnWidth(min: 200, ideal: 220, max: 280)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle("Workspace")
    .navigationSubtitle(navigationSubtitle)
    .toolbar { windowToolbar }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceWindow)
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
      .harnessMCPTextField(
        HarnessMonitorAccessibility.decisionBulkDismissVisibleInput,
        label: "Dismiss all visible decision confirmation",
        value: dismissAllVisibleDraft
      )
      Button("Dismiss selected visible") {
        Task { await confirmDismissAllVisible() }
      }
      .disabled(dismissAllVisibleDraft != "\(pendingDismissBatch?.count ?? -1)")
      .harnessMCPButton(
        HarnessMonitorAccessibility.decisionBulkDismissVisibleConfirm,
        label: "Dismiss selected visible decisions",
        enabled: dismissAllVisibleDraft == "\(pendingDismissBatch?.count ?? -1)"
      )
      Button("Cancel", role: .cancel) {}
        .harnessMCPButton(
          HarnessMonitorAccessibility.decisionBulkDismissVisibleCancel,
          label: "Cancel dismiss all visible decisions"
        )
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
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionBulkDismissSelected,
        label: "Dismiss selected decision",
        enabled: selection != nil
      )

      Button("Dismiss all visible") {
        beginDismissAllVisible()
      }
      .disabled(visibleOpenDecisionIDs.isEmpty)
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionBulkDismissVisible,
        label: "Dismiss all visible decisions",
        enabled: !visibleOpenDecisionIDs.isEmpty
      )

      if let reopenBatch {
        Button("Reopen dismissed batch") {
          Task { await reopenDismissedBatch(reopenBatch) }
        }
        .harnessMCPMenuItem(
          HarnessMonitorAccessibility.decisionBulkReopenBatch,
          label: "Reopen dismissed batch"
        )
      }

      Button(
        decisionWorkspaceScope.hasActiveFilters
          ? "Snooze filtered critical for 1h"
          : "Snooze visible critical for 1h"
      ) {
        Task { await snoozeAllCritical() }
      }
      .disabled(criticalDecisionIDs.isEmpty)
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionBulkSnoozeCritical,
        label: decisionWorkspaceScope.hasActiveFilters
          ? "Snooze filtered critical for 1 hour"
          : "Snooze visible critical for 1 hour",
        enabled: !criticalDecisionIDs.isEmpty
      )

      Button(
        decisionWorkspaceScope.hasActiveFilters
          ? "Dismiss filtered info"
          : "Dismiss visible info"
      ) {
        Task { await dismissAllInfo() }
      }
      .disabled(infoDecisionIDs.isEmpty)
      .harnessMCPMenuItem(
        HarnessMonitorAccessibility.decisionBulkDismissInfo,
        label: decisionWorkspaceScope.hasActiveFilters
          ? "Dismiss filtered info decisions"
          : "Dismiss visible info decisions",
        enabled: !infoDecisionIDs.isEmpty
      )
    } label: {
      Label("Bulk actions", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .help("Bulk actions")
    .harnessMCPButton(
      HarnessMonitorAccessibility.decisionBulkActions,
      label: "Decision bulk actions"
    )
  }

  private var inspectorToggleButton: some View {
    Button {
      inspectorVisible.toggle()
    } label: {
      Label(inspectorToggleLabel, systemImage: "sidebar.right")
    }
    .keyboardShortcut("i", modifiers: [.command, .option])
    .help(inspectorToggleLabel)
    .harnessMCPButton(
      HarnessMonitorAccessibility.decisionInspectorToggle,
      label: inspectorToggleLabel
    )
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
    pendingDismissBatch = WorkspaceDecisionDismissBatchSnapshot(
      ids: ids,
      count: ids.count,
      filterSignature: visibleSnapshot.signature,
      scopeDescription: decisionWorkspaceScope.scopeDescription,
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
    return "Scope: \(snapshot.scopeDescription)\nCaptured: \(capturedAt)"
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
    reopenBatch = WorkspaceDecisionReopenBatchState(
      ids: snapshot.ids,
      expiresAt: Date().addingTimeInterval(15)
    )
    pendingDismissBatch = nil
    dismissAllVisibleDraft = ""
  }

  private func reopenDismissedBatch(_ batch: WorkspaceDecisionReopenBatchState) async {
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
