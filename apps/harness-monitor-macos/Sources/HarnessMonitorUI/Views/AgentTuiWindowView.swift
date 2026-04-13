import AppKit
import HarnessMonitorKit
import SwiftUI

private struct ClickableSwitchStyle: ToggleStyle {
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

  @State private var displayState = AgentTuiDisplayState()
  @State private var runtime: AgentTuiRuntime = .copilot
  @State private var name = ""
  @State private var prompt = ""
  @State private var projectDir = ""
  @State private var argvOverride = ""
  @State private var inputText = ""
  @State private var inputMode: AgentTuiInputMode = .text
  @State private var rows = 32
  @State private var cols = 120
  @State private var isSubmitting = false
  @State private var selection: AgentTuiSheetSelection = .create
  @State private var wrapLines = false
  @State private var selectedPersona: String?
  @State private var availablePersonas: [AgentPersona] = []
  @State private var expandedPersonaInfo: String?
  @State private var navigationBackStack: [AgentTuiSheetSelection] = []
  @State private var navigationForwardStack: [AgentTuiSheetSelection] = []
  @State private var suppressHistoryRecording = false
  @State private var windowNavigation = WindowNavigationState()
  @State private var pendingViewportResizeTarget: AgentTuiSize?
  @State private var viewportResizeTask: Task<Void, Never>?
  @Environment(\.fontScale)
  private var fontScale
  @FocusState private var focusedField: Field?

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

  private struct TerminalViewportSizing {
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

  private let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  private var selectedAgentNames: [AgentNameMapping] {
    (store.selectedSession?.agents ?? []).map {
      AgentNameMapping(agentID: $0.agentId, name: $0.name)
    }
  }

  private var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = selection.sessionID else {
      return nil
    }
    return displayState.sortedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  private var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedProjectDir: String? {
    let normalized = projectDir.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private var parsedArgvOverride: [String] {
    argvOverride
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var canStart: Bool {
    !isSubmitting && rows > 0 && cols > 0
  }

  private var canSend: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && !trimmedInput.isEmpty && !isSubmitting
  }

  private var canResize: Bool {
    guard let selectedSessionTui else {
      return false
    }
    return selectedSessionTui.status.isActive && rows > 0 && cols > 0 && !isSubmitting
  }

  private var canStop: Bool {
    selectedSessionTui?.status.isActive == true && !isSubmitting
  }

  private var orderedSessionIDs: [String] {
    displayState.sortedAgentTuis.map(\.tuiId)
  }

  private var usesLiveViewportSplitLayout: Bool {
    selectedSessionTui?.status.isActive == true
  }

  private var currentStateMarker: String {
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

  private var scrollContainerIdentity: String {
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

  @ViewBuilder private var detailColumnContent: some View {
    if usesLiveViewportSplitLayout, let selectedSessionTui {
      sessionPane(selectedSessionTui)
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(scrollContainerIdentity)
    } else if case .create = selection {
      ScrollView {
        createPane
          .padding(HarnessMonitorTheme.spacingLG)
      }
      .id(scrollContainerIdentity)
    } else {
      ScrollView {
        paneContent
          .padding(HarnessMonitorTheme.spacingLG)
      }
      .id(scrollContainerIdentity)
    }
  }

  @ViewBuilder private var paneContent: some View {
    switch selection {
    case .create:
      createPane
    case .session:
      if let selectedSessionTui {
        sessionPane(selectedSessionTui)
      } else {
        unavailableSessionPane
      }
    }
  }

  private var createPane: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if displayState.agentTuiUnavailable {
        agentTuiUnavailableBanner
      }
      launchSection
      Text(
        !displayState.hasAgentTuis
          ? "Start a terminal-backed agent to inspect the live screen and steer it from Harness Monitor."
          : "Open Agent TUI sessions stay pinned in the sidebar so you can launch another agent without losing the active terminal."
      )
      .scaledFont(.subheadline)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiLaunchPane)
  }

  private var unavailableSessionPane: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("That Agent TUI session is no longer available.")
        .scaledFont(.headline)
      Button("Back to create") {
        selectCreateTab()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiBackToCreateButton)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  private var launchSection: some View {
    launchForm
  }

  private var launchForm: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("New agent")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Picker("Runtime", selection: $runtime) {
            ForEach(AgentTuiRuntime.allCases) { runtime in
              Text(runtime.title).tag(runtime)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRuntimePicker)
          if !availablePersonas.isEmpty {
            inlinePersonaGrid
          }
          TextField("Optional display name", text: $name)
            .harnessNativeFormControl()
            .focused($focusedField, equals: .name)
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNameField)
          multilineEditor(
            placeholder: "Optional first prompt to submit inside the TUI",
            text: $prompt,
            field: .prompt,
            minHeight: 72,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiPromptField
          )
          TextField("Optional project directory override", text: $projectDir)
            .harnessNativeFormControl()
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiProjectDirField)
          multilineEditor(
            placeholder:
              "Optional argv override (one argument per line; first line is the executable)",
            text: $argvOverride,
            field: .argv,
            minHeight: 88,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiArgvField
          )
        }

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Text("Terminal size")
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Stepper("Rows \(rows)", value: $rows, in: TerminalViewportSizing.rowRange)
          Stepper("Cols \(cols)", value: $cols, in: TerminalViewportSizing.colRange, step: 10)
          Spacer(minLength: 0)
          HarnessMonitorActionButton(
            title: "Start \(runtime.title)",
            variant: .prominent,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiStartButton,
            fillsWidth: true
          ) {
            startTui()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(!canStart)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentTuiStartButton,
            label: "Start \(runtime.title)"
          )
        }
        .frame(width: 240, alignment: .topLeading)
      }
    }
  }

  private static let personaColumns = [
    GridItem(.adaptive(minimum: 140), spacing: HarnessMonitorTheme.spacingMD)
  ]

  private var inlinePersonaGrid: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Persona")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      LazyVGrid(columns: Self.personaColumns, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(availablePersonas, id: \.identifier) { persona in
          personaCardButton(persona)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPersonaPicker)
  }

  private func personaCardButton(_ persona: AgentPersona) -> some View {
    let isSelected = selectedPersona == persona.identifier
    return Button {
      selectedPersona = isSelected ? nil : persona.identifier
    } label: {
      VStack(spacing: HarnessMonitorTheme.spacingSM) {
        PersonaSymbolView(symbol: persona.symbol, size: 40)
          .foregroundStyle(isSelected ? HarnessMonitorTheme.accent : .secondary)
        Text(persona.name)
          .scaledFont(.callout.weight(.medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      .frame(minWidth: 120, minHeight: 100)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .topTrailing) {
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(HarnessMonitorTheme.accent)
            .font(.system(size: 14))
            .padding(HarnessMonitorTheme.spacingXS)
        }
      }
    }
    .harnessInteractiveCardButtonStyle(tint: isSelected ? HarnessMonitorTheme.accent : nil)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPersonaCard(persona.identifier))
    .accessibilityLabel(persona.name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .popover(
      isPresented: Binding(
        get: { expandedPersonaInfo == persona.identifier },
        set: { if !$0 { expandedPersonaInfo = nil } }
      )
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text(persona.name)
          .scaledFont(.headline)
        Text(persona.description)
          .scaledFont(.body)
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(maxWidth: 280)
    }
    .contextMenu {
      Button("Learn more") {
        expandedPersonaInfo = persona.identifier
      }
    }
  }

  private func sessionPane(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      terminalHeader(tui)
      if tui.status.isActive {
        liveSessionLayout(tui)
      } else {
        terminalViewport(tui)
        if let error = tui.error, !error.isEmpty {
          terminalError(error)
        }
        terminalOutcome(tui)
      }
    }
    .frame(
      maxWidth: .infinity, maxHeight: tui.status.isActive ? .infinity : nil, alignment: .topLeading
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  private func liveSessionLayout(_ tui: AgentTuiSnapshot) -> some View {
    VSplitView {
      terminalViewport(tui)
        .frame(
          minHeight: TerminalViewportSizing.minimumViewportHeight,
          idealHeight: TerminalViewportSizing.idealViewportHeight
        )

      ScrollView {
        liveSessionControls(tui)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, HarnessMonitorTheme.spacingXS)
      }
      .frame(minHeight: TerminalViewportSizing.minimumControlsHeight)
      .accessibilityIdentifier("harness.sheet.agent-tui.controls")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func liveSessionControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if let error = tui.error, !error.isEmpty {
        terminalError(error)
      }
      terminalInputControls(tui)
      terminalKeyControls(tui)
      terminalResizeControls()
    }
  }

  @ToolbarContentBuilder private var agentTuiNavigationToolbarItems: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        navigateHistoryBack()
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!windowNavigation.canGoBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNavigateBackButton)

      Button {
        navigateHistoryForward()
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!windowNavigation.canGoForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNavigateForwardButton)
    }
  }

  @ToolbarContentBuilder private var sessionToolbarItems: some ToolbarContent {
    if let selectedSessionTui {
      ToolbarItem(placement: .primaryAction) {
        Button {
          revealTranscript(selectedSessionTui)
        } label: {
          Label("Transcript", systemImage: "doc.text")
        }
        .help("Reveal transcript in Finder")
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRevealTranscriptButton)
      }

      if selectedSessionTui.status.isActive {
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
          Button {
            stopTui(selectedSessionTui)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .disabled(!canStop)
          .help("Stop this agent TUI session")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiStopButton)
        }
      }
    }
  }

  private func terminalHeader(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(resolvedTitle(for: tui))
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      HStack(alignment: .firstTextBaseline) {
        Text("\(tui.status.title) • \(tui.size.rows)x\(tui.size.cols)")
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Toggle("Wrap lines", isOn: $wrapLines)
          .toggleStyle(ClickableSwitchStyle())
          .scaledFont(.caption)
          .controlSize(.mini)
          .keyboardShortcut("l", modifiers: [.command])
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiWrapToggle)
      }
    }
  }

  private func terminalViewport(_ tui: AgentTuiSnapshot) -> some View {
    ScrollView(wrapLines ? .vertical : [.horizontal, .vertical]) {
      Text(tui.screen.text.isEmpty ? "No terminal output yet." : tui.screen.text)
        .scaledFont(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HarnessMonitorTheme.spacingMD)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: TerminalViewportSizing.minimumViewportHeight,
      idealHeight: TerminalViewportSizing.idealViewportHeight,
      maxHeight: tui.status.isActive ? .infinity : TerminalViewportSizing.idealViewportHeight
    )
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { viewportSize in
      updateViewportGeometry(viewportSize, for: tui)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiViewport)
  }

  private func terminalError(_ error: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Error")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(error)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.danger)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func terminalOutcome(_ tui: AgentTuiSnapshot) -> some View {
    if !tui.status.isActive {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Exit")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        if let exitCode = tui.exitCode {
          Text("Exit code \(exitCode)")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        if let signal = tui.signal, !signal.isEmpty {
          Text("Signal \(signal)")
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
      }
    }
  }

  private func terminalInputControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Input")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker("Input mode", selection: $inputMode) {
        ForEach(AgentTuiInputMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiInputModePicker)
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        multilineEditor(
          placeholder: "Text to send to the TUI",
          text: $inputText,
          field: .input,
          minHeight: 72,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiInputField
        )
        HarnessMonitorActionButton(
          title: "Send",
          variant: .bordered,
          accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiSendButton
        ) {
          sendInput(to: tui)
        }
        .disabled(!canSend)
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.agentTuiSendButton,
          label: "Send"
        )
      }
    }
  }

  private func terminalKeyControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Keys")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        ForEach(commonKeys) { key in
          Button {
            sendKey(key, to: tui)
          } label: {
            Text(key.glyph)
              .lineLimit(1)
              .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
              .frame(minWidth: 44)
          }
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .controlSize(HarnessMonitorControlMetrics.compactControlSize)
          .disabled(!tui.status.isActive || isSubmitting)
          .accessibilityLabel(key.title)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton(key.rawValue))
          .help(key.title)
        }
        Button {
          sendControl("c", to: tui)
        } label: {
          Text("⌃C")
            .lineLimit(1)
            .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
            .frame(minWidth: 44)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(!tui.status.isActive || isSubmitting)
        .accessibilityLabel("Control-C")
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton("ctrl-c"))
        .help("Control-C")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func terminalResizeControls() -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Viewport")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text("Drag the divider below the output or resize the window to sync the live TUI.")
        .scaledFont(.footnote)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        Stepper("Rows \(rows)", value: $rows, in: TerminalViewportSizing.rowRange)
        Stepper("Cols \(cols)", value: $cols, in: TerminalViewportSizing.colRange, step: 10)
        Spacer()
        if let selectedSessionTui {
          HarnessMonitorActionButton(
            title: "Apply Size",
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiResizeButton
          ) {
            resizeTui(selectedSessionTui)
          }
          .disabled(!canResize)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentTuiResizeButton,
            label: "Apply Size"
          )
        }
      }
    }
  }

  private func multilineEditor(
    placeholder: String,
    text: Binding<String>,
    field: Field,
    minHeight: CGFloat,
    accessibilityIdentifier: String
  ) -> some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))

      if text.wrappedValue.isEmpty {
        Text(placeholder)
          .scaledFont(.body)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .padding(.horizontal, HarnessMonitorTheme.spacingMD)
          .padding(.vertical, HarnessMonitorTheme.spacingSM)
          .allowsHitTesting(false)
      }

      TextEditor(text: text)
        .scaledFont(.body)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
        .focused($focusedField, equals: field)
    }
    .frame(minHeight: minHeight)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var agentTuiUnavailableBanner: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(agentTuiBridgeTitle, systemImage: "exclamationmark.triangle")
        .scaledFont(.headline)
        .foregroundStyle(.orange)
      Text(agentTuiBridgeMessage)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if agentTuiBridgeState == .excluded && hostBridge.running {
        Button("Enable now") {
          Task {
            _ = await store.setHostBridgeCapability("agent-tui", enabled: true)
          }
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .disabled(store.isDaemonActionInFlight || isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiEnableBridgeButton)
      }
      CopyableCommandBox(
        command: agentTuiBridgeCommand,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiCopyCommandButton
      )
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRecoveryBanner)
  }

  private var agentTuiBridgeState: HarnessMonitorStore.HostBridgeCapabilityState {
    store.hostBridgeCapabilityState(for: "agent-tui")
  }

  private var agentTuiBridgeCommand: String {
    store.hostBridgeStartCommand(for: "agent-tui")
  }

  private var hostBridge: HostBridgeManifest {
    store.daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
  }

  private var agentTuiBridgeCapabilityPresent: Bool {
    hostBridge.capabilities["agent-tui"] != nil
  }

  private var agentTuiBridgeTitle: String {
    switch agentTuiBridgeState {
    case .excluded:
      "Agent TUI is excluded from the host bridge"
    case .unavailable:
      "Agent TUI host bridge is not running"
    case .ready:
      "Agent TUI host bridge ready"
    }
  }

  private var agentTuiBridgeMessage: String {
    switch agentTuiBridgeState {
    case .excluded:
      "The shared host bridge is running without terminal control enabled. Enable it now or run this in a terminal:"
    case .unavailable:
      if hostBridge.running && agentTuiBridgeCapabilityPresent {
        "The shared host bridge is running, but terminal control is unavailable. Re-enable it or run this in a terminal:"
      } else {
        "Harness Monitor runs sandboxed and needs the host bridge to start or steer terminal-backed agents. Run this in a terminal:"
      }
    case .ready:
      ""
    }
  }

  private func refreshDisplayState() {
    let nextState = AgentTuiDisplayState(store: store)
    guard displayState != nextState else {
      return
    }
    displayState = nextState
  }

  private func resolvedTitle(for tui: AgentTuiSnapshot) -> String {
    displayState.sessionTitlesByID[tui.tuiId] ?? resolvedRuntimeTitle(for: tui)
  }

  private func resolvedRuntimeTitle(for tui: AgentTuiSnapshot) -> String {
    Self.runtimeTitle(for: tui)
  }

  private static func runtimeTitle(for tui: AgentTuiSnapshot) -> String {
    if let runtime = AgentTuiRuntime(rawValue: tui.runtime) {
      return runtime.title
    }

    if let suffix = tui.agentId.split(separator: "-").last, !suffix.isEmpty {
      return "Agent \(suffix)"
    }

    return tui.runtime.capitalized
  }

  private static func initialSelection(
    displayState: AgentTuiDisplayState,
    selectedTuiID: String?
  ) -> AgentTuiSheetSelection {
    let orderedSessionIDs = displayState.sortedAgentTuis.map(\.tuiId)
    if let selectedTuiID, orderedSessionIDs.contains(selectedTuiID) {
      return .session(selectedTuiID)
    }
    if let fallbackTuiID = orderedSessionIDs.first {
      return .session(fallbackTuiID)
    }
    return .create
  }

  private func selectCreateTab() {
    selection = .create
  }

  private func refresh() {
    isSubmitting = true
    Task {
      if selection.sessionID != nil,
        store.selectedAgentTui?.tuiId == selection.sessionID
      {
        _ = await store.refreshSelectedAgentTui()
      } else {
        _ = await store.refreshSelectedAgentTuis()
      }
      reconcileSheetState(afterRefresh: false)
      syncTerminalSize()
      isSubmitting = false
    }
  }

  private func startTui() {
    isSubmitting = true
    Task {
      let success = await store.startAgentTui(
        runtime: runtime,
        name: name,
        prompt: prompt,
        projectDir: trimmedProjectDir,
        persona: selectedPersona,
        argv: parsedArgvOverride,
        rows: rows,
        cols: cols
      )
      if success, let startedTuiID = store.selectedAgentTui?.tuiId {
        name = ""
        prompt = ""
        projectDir = ""
        argvOverride = ""
        inputText = ""
        selectedPersona = nil
        selection = .session(startedTuiID)
        focusedField = .input
      }
      isSubmitting = false
    }
  }

  private func sendInput(to tui: AgentTuiSnapshot) {
    let payload: AgentTuiInput =
      switch inputMode {
      case .text:
        .text(trimmedInput)
      case .paste:
        .paste(trimmedInput)
      }

    isSubmitting = true
    Task {
      let success = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: payload)
      if success {
        inputText = ""
      }
      isSubmitting = false
    }
  }

  private func sendKey(_ key: AgentTuiKey, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .key(key))
      isSubmitting = false
    }
  }

  private func sendControl(_ key: Character, to tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.sendAgentTuiInput(tuiID: tui.tuiId, input: .control(key))
      isSubmitting = false
    }
  }

  private func resizeTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.resizeAgentTui(tuiID: tui.tuiId, rows: rows, cols: cols)
      isSubmitting = false
    }
  }

  private func stopTui(_ tui: AgentTuiSnapshot) {
    isSubmitting = true
    Task {
      _ = await store.stopAgentTui(tuiID: tui.tuiId)
      isSubmitting = false
    }
  }

  private func revealTranscript(_ tui: AgentTuiSnapshot) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tui.transcriptPath)])
  }

  private func updateViewportGeometry(_ viewportSize: CGSize, for tui: AgentTuiSnapshot) {
    guard selection.sessionID == tui.tuiId, tui.status.isActive else {
      return
    }
    guard
      let terminalSize = TerminalViewportSizing.terminalSize(
        for: viewportSize,
        fontScale: fontScale
      )
    else {
      return
    }
    if rows != terminalSize.rows {
      rows = terminalSize.rows
    }
    if cols != terminalSize.cols {
      cols = terminalSize.cols
    }
    guard terminalSize != tui.size, terminalSize != pendingViewportResizeTarget else {
      return
    }

    pendingViewportResizeTarget = terminalSize
    viewportResizeTask?.cancel()
    let tuiID = tui.tuiId
    viewportResizeTask = Task { @MainActor in
      try? await Task.sleep(for: TerminalViewportSizing.debounce)
      guard !Task.isCancelled else {
        return
      }
      guard
        selection.sessionID == tuiID,
        selectedSessionTui?.status.isActive == true
      else {
        if pendingViewportResizeTarget == terminalSize {
          pendingViewportResizeTarget = nil
        }
        return
      }

      let resized = await store.resizeAgentTui(
        tuiID: tuiID,
        rows: terminalSize.rows,
        cols: terminalSize.cols,
        feedback: .silent
      )
      guard pendingViewportResizeTarget == terminalSize else {
        return
      }
      pendingViewportResizeTarget = nil
      if !resized {
        syncTerminalSize()
      }
    }
  }

  private func cancelPendingViewportResize() {
    viewportResizeTask?.cancel()
    viewportResizeTask = nil
    pendingViewportResizeTarget = nil
  }

  private func syncTerminalSize() {
    guard let selectedSessionTui else {
      return
    }
    if pendingViewportResizeTarget == selectedSessionTui.size {
      pendingViewportResizeTarget = nil
    }
    if rows != selectedSessionTui.size.rows {
      rows = selectedSessionTui.size.rows
    }
    if cols != selectedSessionTui.size.cols {
      cols = selectedSessionTui.size.cols
    }
  }

  private func reconcileSheetState(afterRefresh: Bool) {
    let preferredSelection = Self.initialSelection(
      displayState: displayState,
      selectedTuiID: store.selectedAgentTui?.tuiId
    )

    if afterRefresh {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    guard let selectedTuiID = selection.sessionID else {
      return
    }

    guard store.selectedAgentTuis.contains(where: { $0.tuiId == selectedTuiID }) else {
      applyProgrammaticSelection(preferredSelection)
      return
    }

    syncTerminalSize()
  }

  private func applyProgrammaticSelection(_ nextSelection: AgentTuiSheetSelection) {
    guard selection != nextSelection else {
      if nextSelection.sessionID != nil {
        syncTerminalSize()
      }
      return
    }
    suppressHistoryRecording = true
    selection = nextSelection
    if nextSelection.sessionID != nil {
      syncTerminalSize()
    }
  }

  private func navigateHistoryBack() {
    guard !navigationBackStack.isEmpty else { return }
    let destination = navigationBackStack.removeLast()
    navigationForwardStack.append(selection)
    suppressHistoryRecording = true
    selection = destination
    updateNavigationState()
  }

  private func navigateHistoryForward() {
    guard !navigationForwardStack.isEmpty else { return }
    let destination = navigationForwardStack.removeLast()
    navigationBackStack.append(selection)
    suppressHistoryRecording = true
    selection = destination
    updateNavigationState()
  }

  private func updateNavigationState() {
    windowNavigation.canGoBack = !navigationBackStack.isEmpty
    windowNavigation.canGoForward = !navigationForwardStack.isEmpty
  }
}
