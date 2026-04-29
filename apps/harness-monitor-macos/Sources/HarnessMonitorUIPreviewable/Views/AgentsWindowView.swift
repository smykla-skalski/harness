import AppKit
import HarnessMonitorKit
import SwiftUI

struct ClickableSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label
        .onTapGesture { configuration.isOn.toggle() }
      Toggle("", isOn: configuration.$isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}

public struct AgentsWindowView: View {
  let store: HarnessMonitorStore
  let navigationBridge: AgentsWindowNavigationBridge
  @Environment(\.openWindow)
  var openWindow
  @State private var stateViewModel: ViewModel
  @AppStorage(HarnessMonitorAgentTuiDefaults.submitSendsEnterKey)
  var submitSendsEnter = HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault
  @Environment(\.fontScale)
  private var stateFontScale
  @FocusState private var stateFocusedField: Field?

  @MainActor
  public init(
    store: HarnessMonitorStore,
    navigationBridge: AgentsWindowNavigationBridge = AgentsWindowNavigationBridge()
  ) {
    self.store = store
    self.navigationBridge = navigationBridge
    let initialDisplayState = AgentTuiDisplayState(store: store)
    let initialSelection = Self.initialSelection(
      displayState: initialDisplayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
    _stateViewModel = State(
      wrappedValue: ViewModel(
        selection: initialSelection,
        displayState: initialDisplayState
      )
    )
  }

  let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  var viewModel: ViewModel { stateViewModel }

  @MainActor var displayState: AgentTuiDisplayState {
    viewModel.displayState
  }

  var fontScale: CGFloat { stateFontScale }

  var focusedField: Field? {
    get { stateFocusedField }
    nonmutating set { stateFocusedField = newValue }
  }

  var focusedFieldBinding: FocusState<Field?>.Binding { $stateFocusedField }

  var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = viewModel.selection.terminalID else {
      return nil
    }
    return displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  var selectedCodexRun: CodexRunSnapshot? {
    guard let selectedRunID = viewModel.selection.codexRunID else {
      return nil
    }
    return displayState.sortedCodexRuns.first { $0.runId == selectedRunID }
  }

  var selectedCodexApprovalItems: [CodexApprovalItem] {
    guard let selectedCodexRun else {
      return []
    }
    return Self.codexApprovalItems(for: selectedCodexRun, decisions: store.supervisorOpenDecisions)
  }

  var trimmedInput: String {
    viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCodexPrompt: String {
    viewModel.codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedCodexContext: String {
    viewModel.codexContext.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedProjectDir: String? {
    let normalized = viewModel.projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  var parsedArgvOverride: [String] {
    viewModel.argvOverride
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var canStartCodex: Bool {
    !viewModel.isSubmitting && !trimmedCodexPrompt.isEmpty
  }

  var canSend: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && !trimmedInput.isEmpty && !viewModel.isSubmitting
  }

  var canResize: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && viewModel.rows > 0 && viewModel.cols > 0
      && !viewModel.isSubmitting
  }

  var canStop: Bool {
    selectedSessionTui?.status.isActive == true && !viewModel.isSubmitting
  }

  var canSteerCodex: Bool {
    guard let selectedCodexRun else {
      return false
    }
    return
      selectedCodexRun.status.isActive
      && !trimmedCodexContext.isEmpty
      && !viewModel.isSubmitting
  }

  var usesLiveViewportSplitLayout: Bool {
    selectedSessionTui?.status.isActive == true
  }

  var liveViewportIsReconciling: Bool {
    guard let selectedSessionTui, selectedSessionTui.status.isActive else {
      return false
    }
    if viewModel.pendingViewportResizeTarget != nil {
      return true
    }
    guard let expectedSize = viewModel.expectedSize else {
      return false
    }
    return selectedSessionTui.size != expectedSize
  }

  public var body: some View {
    @Bindable var viewModel = viewModel
    let displayState = displayState
    return NavigationSplitView {
      AgentsSidebar(
        selection: $viewModel.selection,
        agentTuis: displayState.sortedAgentTuis,
        sessionTitlesByID: displayState.sessionTitlesByID,
        codexRuns: displayState.sortedCodexRuns,
        codexTitlesByID: displayState.codexTitlesByID,
        externalAgents: displayState.externalAgents,
        pendingDecisionAttention: pendingDecisionAttentionByAgentID,
        openPendingDecisions: openPendingDecisions,
        tasks: store.selectedSession?.tasks ?? [],
        refresh: refresh
      )
      .navigationSplitViewColumnWidth(
        min: PreferencesChromeMetrics.sidebarMinWidth,
        ideal: PreferencesChromeMetrics.sidebarIdealWidth,
        max: PreferencesChromeMetrics.sidebarMaxWidth
      )
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      detailColumnContent
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      agentTuiNavigationToolbarItems
      sessionToolbarItems
    }
    .toolbarBaselineOverlay()
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .task {
      viewModel.windowNavigation.setHandlers(
        back: { navigateHistoryBack() },
        forward: { navigateHistoryForward() }
      )
      navigationBridge.update(viewModel.windowNavigation)
      await Task.yield()
      await loadAgentPickerCatalogs()
      refreshDisplayState()
      reconcileSheetState(afterRefresh: true)
      consumePendingAgentsWindowSelection()
    }
    .onChange(of: store.pendingAgentsWindowSelection) { _, _ in
      consumePendingAgentsWindowSelection()
    }
    .onChange(of: store.selectedAgentTuis) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedCodexRuns) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.agentTuiUnavailable) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.codexUnavailable) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedSession) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedAgentTui?.tuiId) { _, selectedTuiID in
      guard let selectedTuiID else {
        return
      }
      if viewModel.selection.terminalID == selectedTuiID,
        let currentSize = selectedSessionTui?.size
      {
        syncTerminalResizeControls(to: currentSize)
        if viewModel.expectedSize == nil {
          viewModel.expectedSize = currentSize
        }
        enforceExpectedSize()
      }
    }
    .onChange(of: viewModel.selection) { oldValue, newValue in
      if oldValue != newValue {
        cancelPendingViewportResize()
        Task {
          await flushPendingKeySequenceIfNeeded()
        }
      }
      if viewModel.suppressHistoryRecording {
        viewModel.suppressHistoryRecording = false
      } else if oldValue != newValue {
        viewModel.navigationBackStack.append(oldValue)
        viewModel.navigationForwardStack.removeAll()
        updateNavigationState()
      }
      switch newValue {
      case .create:
        break
      case .terminal(let sessionID):
        guard oldValue.terminalID != sessionID else { return }
        store.selectAgentTui(tuiID: sessionID)
        if let currentSize = selectedSessionTui?.size {
          syncTerminalResizeControls(to: currentSize)
          viewModel.expectedSize = currentSize
        }
        enforceExpectedSize()
      case .codex(let runID):
        guard oldValue.codexRunID != runID else { return }
        store.selectCodexRun(runID: runID)
      case .agent:
        break
      case .task:
        break
      }
    }
    .onDisappear {
      cancelPendingViewportResize()
      Task {
        await flushPendingKeySequenceIfNeeded()
      }
      navigationBridge.update(WindowNavigationState())
    }
    .acpPermissionPresentation(store: store)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
  }

}
