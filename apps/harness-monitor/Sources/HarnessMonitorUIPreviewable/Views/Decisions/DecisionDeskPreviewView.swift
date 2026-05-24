import HarnessMonitorKit
import SwiftUI

let decisionDeskDetailPreparationWorker = DecisionDetailPreparationWorker()

public struct DecisionDeskPreviewView: View {
  let store: HarnessMonitorStore?

  @State private var selectionStorage: String?
  @State private var detailTabStorage: DecisionDetailTab = .context
  @State private var runtimeStorage = DecisionRuntime()
  @State private var presentationWorkerStorage = DecisionsSidebarPresentationWorker()
  @State private var cachedPresentationStorage = DecisionsSidebarPresentation.empty
  @State private var presentationGenerationStorage: UInt64 = 0
  @State private var sidebarFiltersStorage = DecisionsSidebarViewModel.FilterState(
    query: "",
    severities: [],
    scope: .summary
  )
  @State private var dismissAllVisibleDraftStorage = ""
  @State private var pendingDismissBatchStorage: DecisionDismissBatchSnapshot?
  @State private var showDismissAllVisibleConfirmationStorage = false
  @State private var reopenBatchStorage: DecisionReopenBatchState?
  @State private var cachedDetailViewModelStorage: DecisionDetailViewModel?
  @State private var cachedDetailViewModelInputStorage: DecisionDetailViewModel.PreparationInput?

  @State private var inspectorVisible = false

  public init(store: HarnessMonitorStore? = nil) {
    self.store = store
  }

  var actionHandler: any DecisionActionHandler {
    store?.supervisorDecisionActionHandler() ?? NullDecisionActionHandler()
  }

  var selection: String? {
    get { selectionStorage }
    nonmutating set { selectionStorage = newValue }
  }

  private var selectionBinding: Binding<String?> {
    $selectionStorage
  }

  var detailTab: DecisionDetailTab {
    get { detailTabStorage }
    nonmutating set { detailTabStorage = newValue }
  }

  private var detailTabBinding: Binding<DecisionDetailTab> {
    $detailTabStorage
  }

  var runtime: DecisionRuntime {
    runtimeStorage
  }

  var presentationWorker: DecisionsSidebarPresentationWorker {
    presentationWorkerStorage
  }

  var cachedPresentation: DecisionsSidebarPresentation {
    get { cachedPresentationStorage }
    nonmutating set { cachedPresentationStorage = newValue }
  }

  var presentationGeneration: UInt64 {
    get { presentationGenerationStorage }
    nonmutating set { presentationGenerationStorage = newValue }
  }

  var sidebarFilters: DecisionsSidebarViewModel.FilterState {
    get { sidebarFiltersStorage }
    nonmutating set { sidebarFiltersStorage = newValue }
  }

  private var sidebarFiltersBinding: Binding<DecisionsSidebarViewModel.FilterState> {
    $sidebarFiltersStorage
  }

  var dismissAllVisibleDraft: String {
    get { dismissAllVisibleDraftStorage }
    nonmutating set { dismissAllVisibleDraftStorage = newValue }
  }

  private var dismissAllVisibleDraftBinding: Binding<String> {
    $dismissAllVisibleDraftStorage
  }

  var pendingDismissBatch: DecisionDismissBatchSnapshot? {
    get { pendingDismissBatchStorage }
    nonmutating set { pendingDismissBatchStorage = newValue }
  }

  var showDismissAllVisibleConfirmation: Bool {
    get { showDismissAllVisibleConfirmationStorage }
    nonmutating set { showDismissAllVisibleConfirmationStorage = newValue }
  }

  private var showDismissAllVisibleConfirmationBinding: Binding<Bool> {
    $showDismissAllVisibleConfirmationStorage
  }

  var reopenBatch: DecisionReopenBatchState? {
    get { reopenBatchStorage }
    nonmutating set { reopenBatchStorage = newValue }
  }

  var cachedDetailViewModel: DecisionDetailViewModel? {
    get { cachedDetailViewModelStorage }
    nonmutating set { cachedDetailViewModelStorage = newValue }
  }

  var cachedDetailViewModelInput: DecisionDetailViewModel.PreparationInput? {
    get { cachedDetailViewModelInputStorage }
    nonmutating set { cachedDetailViewModelInputStorage = newValue }
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
        selectedTab: detailTabBinding,
        observer: sessionObserver,
        decisionScope: decisionWorkspaceScope,
        primaryActionFocusDecisionID: store?.supervisorPrimaryActionFocusDecisionID,
        primaryActionFocusRequestTick: store?.supervisorPrimaryActionFocusRequestTick ?? 0
      )
    } else {
      DecisionDetailView(
        selectedTab: detailTabBinding,
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
        selection: selectionBinding,
        filters: sidebarFiltersBinding,
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
      isPresented: showDismissAllVisibleConfirmationBinding,
      titleVisibility: .visible
    ) {
      TextField(
        "Type \(pendingDismissBatch?.count ?? 0) to confirm",
        text: dismissAllVisibleDraftBinding
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
