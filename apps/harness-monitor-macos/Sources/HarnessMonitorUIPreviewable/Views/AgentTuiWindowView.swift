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

public struct AgentTuiWindowView: View {
  let store: HarnessMonitorStore
  let navigationBridge: AgentTuiWindowNavigationBridge
  @State private var stateViewModel: ViewModel
  @AppStorage(HarnessMonitorAgentTuiDefaults.submitSendsEnterKey)
  var submitSendsEnter = HarnessMonitorAgentTuiDefaults.submitSendsEnterDefault
  @Environment(\.fontScale)
  private var stateFontScale
  @FocusState private var stateFocusedField: Field?

  @MainActor
  public init(
    store: HarnessMonitorStore,
    navigationBridge: AgentTuiWindowNavigationBridge = AgentTuiWindowNavigationBridge()
  ) {
    self.store = store
    self.navigationBridge = navigationBridge
    let initialDisplayState = AgentTuiDisplayState(store: store)
    let initialSelection = Self.initialSelection(
      displayState: initialDisplayState,
      selectedTerminalID: store.selectedAgentTui?.tuiId,
      selectedCodexRunID: store.selectedCodexRun?.runId
    )
    _stateViewModel = State(wrappedValue: ViewModel(selection: initialSelection))
  }

  let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  var viewModel: ViewModel { stateViewModel }

  @MainActor var displayState: AgentTuiDisplayState {
    AgentTuiDisplayState(store: store)
  }

  var fontScale: CGFloat { stateFontScale }

  var focusedField: Field? {
    get { stateFocusedField }
    nonmutating set { stateFocusedField = newValue }
  }

  var focusedFieldBinding: FocusState<Field?>.Binding { $stateFocusedField }

  var selectedAgentNames: [AgentNameMapping] {
    (store.selectedSession?.agents ?? []).map {
      AgentNameMapping(agentID: $0.agentId, name: $0.name)
    }
  }

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

  var canStartTerminal: Bool {
    !viewModel.isSubmitting && viewModel.rows > 0 && viewModel.cols > 0
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

  var currentStateMarker: String {
    switch viewModel.selection {
    case .create:
      return "selection=create"
    case .terminal(let sessionID):
      let status = selectedSessionTui?.status.rawValue ?? "missing"
      let sizeLabel =
        if let selectedSessionTui {
          "size=\(selectedSessionTui.size.rows)x\(selectedSessionTui.size.cols)"
        } else {
          "size=missing"
        }
      return
        "selection=terminal:\(sessionID),status=\(status),wrap=\(viewModel.wrapLines),\(sizeLabel)"
    case .codex(let runID):
      let status = selectedCodexRun?.status.rawValue ?? "missing"
      let approvalCount = selectedCodexRun?.pendingApprovals.count ?? 0
      return "selection=codex:\(runID),status=\(status),approvals=\(approvalCount)"
    }
  }

  var scrollContainerIdentity: String {
    switch viewModel.selection {
    case .create:
      "create"
    case .terminal(let sessionID):
      "terminal:\(sessionID)"
    case .codex(let runID):
      "codex:\(runID)"
    }
  }

  public var body: some View {
    @Bindable var viewModel = viewModel
    let displayState = displayState
    return NavigationSplitView {
      AgentTuiSidebar(
        selection: $viewModel.selection,
        agentTuis: displayState.sortedAgentTuis,
        sessionTitlesByID: displayState.sessionTitlesByID,
        codexRuns: displayState.sortedCodexRuns,
        codexTitlesByID: displayState.codexTitlesByID,
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
      async let tuiRefresh = store.refreshSelectedAgentTuis()
      async let codexRefresh = store.refreshSelectedCodexRuns()
      async let personas = store.fetchPersonas()
      async let runtimeModels = store.fetchRuntimeModelCatalogs()
      let loadedPersonas = await personas
      let loadedRuntimeModels = await runtimeModels
      _ = await tuiRefresh
      _ = await codexRefresh
      if viewModel.availablePersonas != loadedPersonas {
        viewModel.availablePersonas = loadedPersonas
      }
      if viewModel.availableRuntimeModels != loadedRuntimeModels {
        viewModel.availableRuntimeModels = loadedRuntimeModels
      }
      reconcileSheetState(afterRefresh: true)
    }
    .onChange(of: store.selectedAgentTuis) { _, _ in
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedCodexRuns) { _, _ in
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.agentTuiUnavailable) { _, _ in
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.codexUnavailable) { _, _ in
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedAgentTui?.tuiId) { _, selectedTuiID in
      guard let selectedTuiID else {
        return
      }
      if viewModel.selection.terminalID == selectedTuiID {
        if viewModel.expectedSize == nil {
          viewModel.expectedSize = AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
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
        viewModel.expectedSize = AgentTuiSize(rows: viewModel.rows, cols: viewModel.cols)
        enforceExpectedSize()
      case .codex(let runID):
        guard oldValue.codexRunID != runID else { return }
        store.selectCodexRun(runID: runID)
      }
    }
    .onDisappear {
      cancelPendingViewportResize()
      Task {
        await flushPendingKeySequenceIfNeeded()
      }
      navigationBridge.update(WindowNavigationState())
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSheet)
    .overlay {
      if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.agentTuiState,
          text: currentStateMarker
        )
      }
    }
  }
}
