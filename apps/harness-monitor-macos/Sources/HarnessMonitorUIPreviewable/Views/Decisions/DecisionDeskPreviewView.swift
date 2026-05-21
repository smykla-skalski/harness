import HarnessMonitorKit
import SwiftUI

let decisionDeskDetailPreparationWorker = DecisionDetailPreparationWorker()

public struct DecisionDeskPreviewView: View {
  let store: HarnessMonitorStore?

  @State private var selection: String?
  @State private var detailTab: DecisionDetailTab = .context
  @State private var runtime = DecisionRuntime()
  @State private var presentationWorker = DecisionsSidebarPresentationWorker()
  @State private var cachedPresentation = DecisionsSidebarPresentation.empty
  @State private var presentationGeneration: UInt64 = 0
  @State private var sidebarFilters = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )
  @State private var dismissAllVisibleDraft = ""
  @State private var pendingDismissBatch: DecisionDismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmation = false
  @State private var reopenBatch: DecisionReopenBatchState?
  @State private var cachedDetailViewModel: DecisionDetailViewModel?
  @State private var cachedDetailViewModelInput: DecisionDetailViewModel.PreparationInput?

  @State private var inspectorVisible = false

  public init(store: HarnessMonitorStore? = nil) {
    self.store = store
  }

  var actionHandler: any DecisionActionHandler {
    store?.supervisorDecisionActionHandler() ?? NullDecisionActionHandler()
  }

  var decisionWorkspaceScope: DecisionWorkspaceScope {
    DecisionWorkspaceScope(
      decisions: runtime.decisions,
      decisionsByID: runtime.decisionsByID,
      filters: sidebarFilters,
      presentation: cachedPresentation,
      selectedDecisionID: selection
    )
  }

  var presentationTaskKey: DecisionsSidebarPresentationTaskKey {
    DecisionsSidebarPresentationTaskKey(
      decisionsRevision: runtime.decisionsRevision,
      decisions: runtime.decisions,
      filters: sidebarFilters
    )
  }

  var selectedDecision: Decision? {
    decisionWorkspaceScope.selectedDecision
  }

  var selectedDecisionPreparationInput: DecisionDetailViewModel.PreparationInput? {
    selectedDecision.map(DecisionDetailViewModel.PreparationInput.init(decision:))
  }

  var currentDetailViewModel: DecisionDetailViewModel? {
    guard cachedDetailViewModelInput == selectedDecisionPreparationInput else {
      return nil
    }
    return cachedDetailViewModel
  }

  var openDecisionCount: Int { decisionWorkspaceScope.totalCount }

  var criticalDecisionCount: Int {
    decisionWorkspaceScope.criticalCount
  }

  var infoDecisionIDs: [String] {
    decisionWorkspaceScope.visibleInfoDecisionIDs
  }

  var criticalDecisionIDs: [String] {
    decisionWorkspaceScope.visibleCriticalDecisionIDs
  }

  var navigationSubtitle: String {
    let openLabel = "\(openDecisionCount) open"
    guard criticalDecisionCount > 0 else {
      return openLabel
    }
    return "\(openLabel) · \(criticalDecisionCount) critical"
  }

  var inspectorToggleLabel: String {
    inspectorVisible ? "Hide Inspector" : "Show Inspector"
  }

  var sessionObserver: ObserverSummary? {
    store?.selectedSession?.observer
  }

  var visibleSnapshot: DecisionsSidebarViewModel.VisibleSnapshot {
    decisionWorkspaceScope.visibleSnapshot
  }

  var visibleOpenDecisionIDs: [String] {
    decisionWorkspaceScope.visibleDecisionIDs
  }

  @ViewBuilder var detailColumn: some View {
    if selectedDecision != nil {
      DecisionDetailView(
        viewModel: currentDetailViewModel,
        store: store,
        auditEvents: runtime.auditEvents,
        auditEventPayloadPresentations: runtime.auditEventPayloadPresentations,
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
        decisionsByID: runtime.decisionsByID,
        decisionItems: runtime.decisionItems,
        decisionsRevision: runtime.decisionsRevision,
        presentation: cachedPresentation,
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
    .navigationTitle("Decisions")
    .navigationSubtitle(navigationSubtitle)
    .toolbar { windowToolbar }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDeskRoot)
    .task {
      syncSelectionFromStoreIfNeeded()
      await reload()
      syncSelectionFromStoreIfNeeded()
    }
    .task(id: store?.supervisorDecisionRefreshTick ?? -1) {
      await reload()
      syncSelectionFromStoreIfNeeded()
    }
    .task(id: presentationTaskKey) {
      await rebuildPresentation()
    }
    .task(id: selectedDecisionPreparationInput) {
      await syncSelectedDecisionViewModel()
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

  @ToolbarContentBuilder var windowToolbar: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      bulkActionsMenu
    }

    ToolbarSpacer(.fixed, placement: .primaryAction)

    ToolbarItem(placement: .primaryAction) {
      inspectorToggleButton
    }
  }

  var bulkActionsMenu: some View {
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

  var inspectorToggleButton: some View {
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

}
