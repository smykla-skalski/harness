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

  @MainActor
  public init(store: HarnessMonitorStore) {
    self.store = store
    let initialDisplayState = AgentTuiDisplayState(store: store)
    _displayState = State(initialValue: initialDisplayState)
    _selection = State(
      initialValue: Self.initialSelection(
        displayState: initialDisplayState,
        selectedTuiID: store.selectedAgentTui?.tuiId
      )
    )
  }

  @State var displayState = AgentTuiDisplayState()
  @State var runtime: AgentTuiRuntime = .copilot
  @State var name = ""
  @State var prompt = ""
  @State var projectDir = ""
  @State var argvOverride = ""
  @State var inputText = ""
  @State var inputMode: AgentTuiInputMode = .text
  @State var rows = 32
  @State var cols = 120
  @State var isSubmitting = false
  @State var selection: AgentTuiSheetSelection = .create
  @State var wrapLines = false
  @State var selectedPersona: String?
  @State var availablePersonas: [AgentPersona] = []
  @State var expandedPersonaInfo: String?
  @State var navigationBackStack: [AgentTuiSheetSelection] = []
  @State var navigationForwardStack: [AgentTuiSheetSelection] = []
  @State var suppressHistoryRecording = false
  @State var windowNavigation = WindowNavigationState()
  @State var pendingViewportResizeTarget: AgentTuiSize?
  @State var viewportResizeTask: Task<Void, Never>?
  @Environment(\.fontScale)
  var fontScale
  @FocusState var focusedField: Field?

  private enum Field: Hashable {
    case name
    case prompt
    case argv
    case input
  }

  private struct AgentNameMapping: Equatable {
    let agentID: String
    let name: String
  }

  private struct AgentTuiDisplayState: Equatable {
    let sortedAgentTuis: [AgentTuiSnapshot]
    let sessionTitlesByID: [String: String]
    let agentTuiUnavailable: Bool

    var hasAgentTuis: Bool {
      !sortedAgentTuis.isEmpty
    }

    init() {
      sortedAgentTuis = []
      sessionTitlesByID = [:]
      agentTuiUnavailable = false
    }

    @MainActor
    init(store: HarnessMonitorStore) {
      let sortedAgentTuis = store.selectedAgentTuis.sorted { left, right in
        if left.status.sortPriority != right.status.sortPriority {
          return left.status.sortPriority < right.status.sortPriority
        }
        if left.runtime != right.runtime {
          return left.runtime < right.runtime
        }
        return left.tuiId < right.tuiId
      }

      let agentNames = Dictionary(
        uniqueKeysWithValues: (store.selectedSession?.agents ?? []).map { ($0.agentId, $0.name) }
      )
      var sessionTitlesByID: [String: String] = [:]
      sessionTitlesByID.reserveCapacity(sortedAgentTuis.count)
      for tui in sortedAgentTuis {
        sessionTitlesByID[tui.tuiId] =
          agentNames[tui.agentId] ?? AgentTuiWindowView.runtimeTitle(for: tui)
      }

      self.sortedAgentTuis = sortedAgentTuis
      self.sessionTitlesByID = sessionTitlesByID
      self.agentTuiUnavailable = store.agentTuiUnavailable
    }
  }

  private enum AgentTuiInputMode: String, CaseIterable, Identifiable {
    case text
    case paste

    var id: String { rawValue }

    var title: String {
      switch self {
      case .text:
        "Type"
      case .paste:
        "Paste"
      }
    }
  }

  private enum TerminalViewportSizing {
    static let rowRange = 8...240
    static let colRange = 20...400
    static let minimumViewportHeight: CGFloat = 220
    static let idealViewportHeight: CGFloat = 320
    static let minimumControlsHeight: CGFloat = 220
    static let minimumMeasuredContentWidth: CGFloat = 160
    static let minimumMeasuredContentHeight: CGFloat = 96
    static let debounce = Duration.milliseconds(120)
    static let contentInsets = CGSize(
      width: HarnessMonitorTheme.spacingMD * 2,
      height: HarnessMonitorTheme.spacingMD * 2
    )

    @MainActor
    static func terminalSize(for viewportSize: CGSize, fontScale: CGFloat) -> AgentTuiSize? {
      let cellSize = measuredCellSize(for: fontScale)
      let usableWidth = max(
        viewportSize.width - contentInsets.width,
        minimumMeasuredContentWidth
      )
      let usableHeight = max(
        viewportSize.height - contentInsets.height,
        minimumMeasuredContentHeight
      )
      let rawRows = Int(floor(usableHeight / cellSize.height))
      let rawCols = Int(floor(usableWidth / cellSize.width))
      guard rawRows > 0, rawCols > 0 else {
        return nil
      }
      return AgentTuiSize(
        rows: min(max(rawRows, rowRange.lowerBound), rowRange.upperBound),
        cols: min(max(rawCols, colRange.lowerBound), colRange.upperBound)
      )
    }

    @MainActor
    private static func measuredCellSize(for fontScale: CGFloat) -> CGSize {
      let pointSize = 13 * max(fontScale, 0.78)
      let font = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
      let width = max(
        ceil(("W" as NSString).size(withAttributes: [.font: font]).width),
        1
      )
      let height = max(ceil(font.ascender - font.descender + font.leading), 1)
      return CGSize(width: width, height: height)
    }
  }

  let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  var selectedAgentNames: [AgentNameMapping] {
    (store.selectedSession?.agents ?? []).map {
      AgentNameMapping(agentID: $0.agentId, name: $0.name)
    }
  }

  var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = selection.sessionID else {
      return nil
    }
    return displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var trimmedProjectDir: String? {
    let normalized = projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  var parsedArgvOverride: [String] {
    argvOverride
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  var canStart: Bool {
    !isSubmitting && rows > 0 && cols > 0
  }

  var canSend: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && !trimmedInput.isEmpty && !isSubmitting
  }

  var canResize: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && rows > 0 && cols > 0 && !isSubmitting
  }

  var canStop: Bool {
    selectedSessionTui?.status.isActive == true && !isSubmitting
  }

  var orderedSessionIDs: [String] {
    displayState.sortedAgentTuis.map(\.tuiId)
  }

  var usesLiveViewportSplitLayout: Bool {
    selectedSessionTui?.status.isActive == true
  }

  var currentStateMarker: String {
    switch selection {
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
      return "selection=session:\(sessionID),status=\(status),wrap=\(wrapLines),\(sizeLabel)"
    }
  }

  var scrollContainerIdentity: String {
    switch selection {
    case .create:
      "create"
    case .session(let sessionID):
      "session:\(sessionID)"
    }
  }

  public var body: some View {
    NavigationSplitView {
      AgentTuiSidebar(
        selection: $selection,
        agentTuis: displayState.sortedAgentTuis,
        sessionTitlesByID: displayState.sessionTitlesByID,
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
    .focusedSceneValue(\.windowNavigation, windowNavigation)
    .task {
      windowNavigation.backHandler = { navigateHistoryBack() }
      windowNavigation.forwardHandler = { navigateHistoryForward() }
      await Task.yield()
      async let tuiRefresh = store.refreshSelectedAgentTuis()
      async let personas = store.fetchPersonas()
      let loadedPersonas = await personas
      _ = await tuiRefresh
      if availablePersonas != loadedPersonas {
        availablePersonas = loadedPersonas
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
      if selection.sessionID == selectedTuiID {
        syncTerminalSize()
      }
    }
    .onChange(of: selection) { oldValue, newValue in
      if oldValue != newValue {
        cancelPendingViewportResize()
      }
      if suppressHistoryRecording {
        suppressHistoryRecording = false
      } else if oldValue != newValue {
        navigationBackStack.append(oldValue)
        navigationForwardStack.removeAll()
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
