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

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  @State private var runtime: AgentTuiRuntime = .copilot
  @State private var name = ""
  @State private var prompt = ""
  @State private var inputText = ""
  @State private var inputMode: AgentTuiInputMode = .text
  @State private var rows = 32
  @State private var cols = 120
  @State private var isSubmitting = false
  @State private var selection: AgentTuiSheetSelection = .create
  @State private var recentTuiIDs: [String] = []
  @State private var hasInitializedSelection = false
  @State private var wrapLines = false
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case name
    case prompt
    case input
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

  private let commonKeys: [AgentTuiKey] = [
    .enter, .tab, .escape, .backspace, .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
  ]

  private var selectedSessionTui: AgentTuiSnapshot? {
    guard let selectedTuiID = selection.sessionID else {
      return nil
    }
    return store.selectedAgentTuis.first { $0.tuiId == selectedTuiID }
  }

  private var sessionTitlesByID: [String: String] {
    var titles: [String: String] = [:]
    titles.reserveCapacity(store.selectedAgentTuis.count)

    let agentNames = Dictionary(
      uniqueKeysWithValues: (store.selectedSession?.agents ?? []).map { ($0.agentId, $0.name) }
    )

    for tui in store.selectedAgentTuis {
      titles[tui.tuiId] = agentNames[tui.agentId] ?? resolvedRuntimeTitle(for: tui)
    }

    return titles
  }

  private var trimmedInput: String {
    inputText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    let currentSessionIDs = Set(store.selectedAgentTuis.map(\.tuiId))
    var seenSessionIDs: Set<String> = []
    var orderedIDs: [String] = []
    orderedIDs.reserveCapacity(currentSessionIDs.count)

    for sessionID in recentTuiIDs where currentSessionIDs.contains(sessionID) {
      if seenSessionIDs.insert(sessionID).inserted {
        orderedIDs.append(sessionID)
      }
    }

    for tui in store.selectedAgentTuis {
      if seenSessionIDs.insert(tui.tuiId).inserted {
        orderedIDs.append(tui.tuiId)
      }
    }

    return orderedIDs
  }

  private var currentStateMarker: String {
    switch selection {
    case .create:
      return "selection=create"
    case .session(let sessionID):
      let status = selectedSessionTui?.status.rawValue ?? "missing"
      return "selection=session:\(sessionID),status=\(status),wrap=\(wrapLines)"
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
        orderedSessionIDs: orderedSessionIDs,
        sessionTitlesByID: sessionTitlesByID,
        refresh: refresh
      )
      .navigationSplitViewColumnWidth(
        min: PreferencesChromeMetrics.sidebarMinWidth,
        ideal: PreferencesChromeMetrics.sidebarIdealWidth,
        max: PreferencesChromeMetrics.sidebarMaxWidth
      )
      .toolbarBaselineFrame(.sidebar)
    } detail: {
      ScrollView {
        paneContent
          .padding(HarnessMonitorTheme.spacingLG)
      }
      .id(scrollContainerIdentity)
      .toolbar {
        sessionToolbarItems
      }
    }
    .navigationSplitViewStyle(.balanced)
    .toolbarBaselineOverlay()
    .toolbarBackgroundVisibility(.automatic, for: .windowToolbar)
    .containerBackground(.windowBackground, for: .window)
    .task {
      await store.refreshSelectedAgentTuis()
      reconcileSheetState(afterRefresh: true)
    }
    .onChange(of: store.selectedAgentTuis) { _, _ in
      reconcileSheetState(afterRefresh: false)
    }
    .onChange(of: store.selectedAgentTui?.tuiId) { _, selectedTuiID in
      guard let selectedTuiID else {
        return
      }
      promoteSession(selectedTuiID)
      if selection.sessionID == selectedTuiID {
        syncTerminalSize()
      }
    }
    .onChange(of: selection) { oldValue, newValue in
      guard case .session(let sessionID) = newValue else { return }
      guard oldValue.sessionID != sessionID else { return }
      promoteSession(sessionID)
      store.selectAgentTui(tuiID: sessionID)
      syncTerminalSize()
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

  @ViewBuilder
  private var paneContent: some View {
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
      if store.agentTuiUnavailable {
        agentTuiUnavailableBanner
      }
      launchSection
      Text(
        store.selectedAgentTuis.isEmpty
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
        }

        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Text("Terminal size")
            .scaledFont(.caption.bold())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Stepper("Rows \(rows)", value: $rows, in: 16 ... 80)
          Stepper("Cols \(cols)", value: $cols, in: 60 ... 220, step: 10)
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

  private func sessionPane(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      terminalHeader(tui)
      terminalViewport(tui)
      if let error = tui.error, !error.isEmpty {
        terminalError(error)
      }
      terminalOutcome(tui)
      if tui.status.isActive {
        terminalInputControls(tui)
        terminalKeyControls(tui)
        terminalResizeControls()
      }
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  @ToolbarContentBuilder
  private var sessionToolbarItems: some ToolbarContent {
    if let selectedSessionTui {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          revealTranscript(selectedSessionTui)
        } label: {
          Label("Transcript", systemImage: "doc.text")
        }
        .help("Reveal transcript in Finder")
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRevealTranscriptButton)

        if selectedSessionTui.status.isActive {
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
    .frame(minHeight: 220, maxHeight: 320)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 90), spacing: HarnessMonitorTheme.itemSpacing)],
        alignment: .leading,
        spacing: HarnessMonitorTheme.itemSpacing
      ) {
        ForEach(commonKeys) { key in
          Button(key.title) {
            sendKey(key, to: tui)
          }
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .disabled(!tui.status.isActive || isSubmitting)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton(key.rawValue))
        }
        Button("Ctrl-C") {
          sendControl("c", to: tui)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: nil)
        .disabled(!tui.status.isActive || isSubmitting)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiKeyButton("ctrl-c"))
      }
    }
  }

  private func terminalResizeControls() -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Viewport")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
        Stepper("Rows \(rows)", value: $rows, in: 16 ... 80)
        Stepper("Cols \(cols)", value: $cols, in: 60 ... 220, step: 10)
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

  private func resolvedTitle(for tui: AgentTuiSnapshot) -> String {
    sessionTitlesByID[tui.tuiId] ?? resolvedRuntimeTitle(for: tui)
  }

  private func resolvedRuntimeTitle(for tui: AgentTuiSnapshot) -> String {
    if let runtime = AgentTuiRuntime(rawValue: tui.runtime) {
      return runtime.title
    }

    if let suffix = tui.agentId.split(separator: "-").last, !suffix.isEmpty {
      return "Agent \(suffix)"
    }

    return tui.runtime.capitalized
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
        rows: rows,
        cols: cols
      )
      if success, let startedTuiID = store.selectedAgentTui?.tuiId {
        name = ""
        prompt = ""
        inputText = ""
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

  private func syncTerminalSize() {
    guard let selectedSessionTui else {
      return
    }
    rows = selectedSessionTui.size.rows
    cols = selectedSessionTui.size.cols
  }

  private func promoteSession(_ sessionID: String) {
    recentTuiIDs.removeAll { candidateID in
      candidateID == sessionID
    }
    recentTuiIDs.insert(sessionID, at: 0)
  }

  private func reconcileSheetState(afterRefresh: Bool) {
    recentTuiIDs = orderedSessionIDs

    if !hasInitializedSelection || afterRefresh {
      hasInitializedSelection = true
      if let selectedTuiID = store.selectedAgentTui?.tuiId ?? orderedSessionIDs.first {
        if selection.sessionID == nil || afterRefresh {
          selection = .session(selectedTuiID)
          promoteSession(selectedTuiID)
          syncTerminalSize()
        }
      } else {
        selection = .create
      }
      return
    }

    guard let selectedTuiID = selection.sessionID else {
      return
    }

    guard store.selectedAgentTuis.contains(where: { $0.tuiId == selectedTuiID }) else {
      if let fallbackTuiID = store.selectedAgentTui?.tuiId ?? orderedSessionIDs.first {
        selection = .session(fallbackTuiID)
        promoteSession(fallbackTuiID)
        syncTerminalSize()
      } else {
        selection = .create
      }
      return
    }

    syncTerminalSize()
  }
}
