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
  @State private var stateViewModel: ViewModel
  @Environment(\.fontScale)
  private var stateFontScale
  @FocusState private var stateFocusedField: Field?

  @MainActor
  public init(store: HarnessMonitorStore) {
    self.store = store
    let initialDisplayState = AgentTuiDisplayState(store: store)
    let initialSelection = Self.initialSelection(
      displayState: initialDisplayState,
      selectedTuiID: store.selectedAgentTui?.tuiId
    )
    _stateViewModel = State(
      wrappedValue: ViewModel(displayState: initialDisplayState, selection: initialSelection)
    )
  }

  let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  var viewModel: ViewModel { stateViewModel }

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
    guard let selectedTuiID = viewModel.selection.sessionID else {
      return nil
    }
    return viewModel.displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  var trimmedInput: String {
    viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
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

  var canStart: Bool {
    !viewModel.isSubmitting && viewModel.rows > 0 && viewModel.cols > 0
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

  var orderedSessionIDs: [String] {
    viewModel.displayState.sortedAgentTuis.map(\.tuiId)
  }

  var usesLiveViewportSplitLayout: Bool {
    selectedSessionTui?.status.isActive == true
  }

  var currentStateMarker: String {
    switch viewModel.selection {
    case .create:
      return "selection=create"
    case .session(let sessionID):
      let status = selectedSessionTui?.status.rawValue ?? "missing"
      let sizeLabel =
        if let selectedSessionTui {
          "size=\(selectedSessionTui.size.rows)x\(selectedSessionTui.size.cols)"
        } else {
          "size=missing"
        }
      return
        "selection=session:\(sessionID),status=\(status),wrap=\(viewModel.wrapLines),\(sizeLabel)"
    }
  }

  var scrollContainerIdentity: String {
    switch viewModel.selection {
    case .create:
      "create"
    case .session(let sessionID):
      "session:\(sessionID)"
    }
  }

  public var body: some View {
    @Bindable var viewModel = viewModel
    return NavigationSplitView {
      AgentTuiSidebar(
        selection: $viewModel.selection,
        agentTuis: viewModel.displayState.sortedAgentTuis,
        sessionTitlesByID: viewModel.displayState.sessionTitlesByID,
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
        .toolbar {
          agentTuiNavigationToolbarItems
          sessionToolbarItems
        }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .focusedSceneValue(\.windowNavigation, viewModel.windowNavigation)
    .task {
      viewModel.windowNavigation.backHandler = { navigateHistoryBack() }
      viewModel.windowNavigation.forwardHandler = { navigateHistoryForward() }
      await Task.yield()
      async let tuiRefresh = store.refreshSelectedAgentTuis()
      async let personas = store.fetchPersonas()
      let loadedPersonas = await personas
      _ = await tuiRefresh
      if viewModel.availablePersonas != loadedPersonas {
        viewModel.availablePersonas = loadedPersonas
      }
      refreshDisplayState()
      reconcileSheetState(afterRefresh: true)
    }
    .onChange(of: store.selectedAgentTuis) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: selectedAgentNames) { _, _ in
      refreshDisplayState()
    }
    .onChange(of: store.agentTuiUnavailable) { _, _ in
      refreshDisplayState()
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedAgentTui?.tuiId) { _, selectedTuiID in
      guard let selectedTuiID else {
        return
      }
      if viewModel.selection.sessionID == selectedTuiID {
        syncTerminalSize()
      }
    }
    .onChange(of: viewModel.selection) { oldValue, newValue in
      if oldValue != newValue {
        cancelPendingViewportResize()
      }
      if viewModel.suppressHistoryRecording {
        viewModel.suppressHistoryRecording = false
      } else if oldValue != newValue {
        viewModel.navigationBackStack.append(oldValue)
        viewModel.navigationForwardStack.removeAll()
        updateNavigationState()
      }
      guard case .session(let sessionID) = newValue else { return }
      guard oldValue.sessionID != sessionID else { return }
      store.selectAgentTui(tuiID: sessionID)
      syncTerminalSize()
    }
    .onDisappear {
      cancelPendingViewportResize()
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
