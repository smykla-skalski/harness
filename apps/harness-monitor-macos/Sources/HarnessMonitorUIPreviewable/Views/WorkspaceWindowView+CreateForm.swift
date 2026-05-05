import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var createPane: some View {
    WorkspaceWindowCreatePane(
      store: store,
      viewModel: viewModel,
      displayState: displayState,
      focusedFieldBinding: focusedFieldBinding,
      startAction: { startTui() }
    )
  }

  @ViewBuilder var createPaneTopChrome: some View {
    if showsCreatePaneTopChrome {
      VStack(spacing: 0) {
        if let message = createPaneSessionActionUnavailableNote {
          createPaneSessionActionBanner(message: message)
          createPaneChromeDivider()
        }
        if viewModel.createMode == .terminal {
          if viewModel.selectedLaunchSelection.isAcp {
            if store.acpUnavailable {
              acpUnavailableBanner
              createPaneChromeDivider()
            }
          } else if store.agentTuiUnavailable {
            agentTuiUnavailableBanner
            createPaneChromeDivider()
          }
        }
        if viewModel.createMode == .codex, store.codexUnavailable {
          codexUnavailableBanner
          createPaneChromeDivider()
        }
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
  }

  private var showsCreatePaneTopChrome: Bool {
    if createPaneSessionActionUnavailableNote != nil {
      return true
    }
    if viewModel.createMode == .terminal {
      if viewModel.selectedLaunchSelection.isAcp {
        return store.acpUnavailable
      }
      return store.agentTuiUnavailable
    }
    return store.codexUnavailable
  }

  private var createPaneSessionActionTitle: String {
    resolvedCreateSessionID == nil ? "Select a session first" : "Session actions unavailable"
  }

  private func createPaneSessionActionBanner(message: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(createPaneSessionActionTitle, systemImage: "info.circle")
        .scaledFont(.headline)
        .foregroundStyle(HarnessMonitorTheme.caution)
      Text(message)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if resolvedCreateSessionID == nil {
        Button("New Session") {
          store.presentedSheet = .newSession
        }
        .harnessActionButtonStyle(variant: .prominent, tint: nil)
        .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNewSessionButton)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(ChromeBannerSurfaceModifier(tint: HarnessMonitorTheme.caution))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionActionBanner)
  }

  private func createPaneChromeDivider() -> some View {
    Rectangle()
      .fill(HarnessMonitorTheme.caution.opacity(0.35))
      .frame(height: 1)
      .accessibilityHidden(true)
  }
}

struct WorkspaceWindowCreatePane: View {
  typealias ViewModel = WorkspaceWindowView.ViewModel
  typealias DisplayState = WorkspaceWindowView.AgentTuiDisplayState
  typealias Field = WorkspaceWindowView.Field
  private static let topAnchorID = "workspace-create-pane-top"

  let store: HarnessMonitorStore
  let viewModel: ViewModel
  let displayState: DisplayState
  let focusedFieldBinding: FocusState<Field?>.Binding
  let startAction: () -> Void

  var body: some View {
    ScrollViewReader { scrollProxy in
      HarnessMonitorColumnScrollView(
        horizontalPadding: HarnessMonitorTheme.spacingLG,
        verticalPadding: HarnessMonitorTheme.spacingLG,
        constrainContentWidth: false,
        readableWidth: false,
        topScrollEdgeEffect: .soft,
        scrollSurfaceIdentifier: HarnessMonitorAccessibility.agentTuiLaunchPane,
        scrollSurfaceLabel: "New agent pane"
      ) {
        // Keep MCP-tracked controls instantiated even while this pane scrolls.
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
          Color.clear
            .frame(height: 0)
            .accessibilityHidden(true)
            .id(Self.topAnchorID)
          createPaneHeader

          switch viewModel.createMode {
          case .terminal:
            terminalCreateContent
          case .codex:
            codexCreateContent
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        launchFloorBar
      }
      .accessibilityElement(children: .contain)
      .onAppear {
        applySavedLaunchPresetIfFresh()
      }
      .task(id: viewModel.selection) {
        await Task.yield()
        scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
      }
    }
  }
}

extension WorkspaceWindowCreatePane {
  var launchFloorBar: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let warning = launchDemotionWarningText {
        Label {
          Text(warning)
            .scaledFont(.caption)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
      }
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingMD) {
        Text(launchSummaryChipText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.middle)
          .accessibilityLabel("Launch summary: \(launchSummaryChipText)")
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        launchActionButton
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingLG)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessPanelGlass()
    .overlay(alignment: .top) {
      Rectangle()
        .fill(HarnessMonitorTheme.controlBorder.opacity(0.4))
        .frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var launchActionButton: some View {
    let button = HarnessMonitorActionButton(
      title: "Start \(launchActionTitle)",
      variant: .prominent,
      accessibilityIdentifier: launchButtonAccessibilityIdentifier,
      fillsWidth: false
    ) {
      startAction()
    }
    .disabled(!canStartCurrentMode)
    if launchDemotionWarningText == nil {
      button.keyboardShortcut(.defaultAction)
    } else {
      button
    }
  }

  var launchDemotionWarningText: String? {
    guard
      viewModel.createMode == .terminal,
      viewModel.selectedRole == .leader,
      let sessionID = resolvedCreateSessionID,
      let summary = store.sessionIndex.sessionSummary(for: sessionID),
      let leaderID = summary.leaderId,
      !leaderID.isEmpty
    else {
      return nil
    }
    let leaderName = resolvedLeaderDisplayName(for: leaderID)
    let fallback = viewModel.selectedAcpFallbackRole.title
    return "Will demote the current leader \(leaderName) to \(fallback)."
  }

  private func resolvedLeaderDisplayName(for leaderID: String) -> String {
    if let runtime = store.acpRuntimeState(for: leaderID) {
      let name = runtime.agentName
      if !name.isEmpty, name != leaderID {
        return "\u{201C}\(name)\u{201D}"
      }
    }
    if let descriptor = viewModel.availableAcpAgents.first(where: { $0.id == leaderID }) {
      return "\u{201C}\(descriptor.displayName)\u{201D}"
    }
    return "(\(leaderID))"
  }

  var launchActionTitle: String {
    switch viewModel.createMode {
    case .terminal:
      selectedAgentLaunchTitle
    case .codex:
      "Codex"
    }
  }

  var launchButtonAccessibilityIdentifier: String {
    switch viewModel.createMode {
    case .terminal:
      HarnessMonitorAccessibility.agentTuiStartButton
    case .codex:
      HarnessMonitorAccessibility.workspaceCodexSubmitButton
    }
  }

  var canStartCurrentMode: Bool {
    switch viewModel.createMode {
    case .terminal:
      canStartTerminal
    case .codex:
      canStartCodex
    }
  }

  var launchSummaryChipText: String {
    switch viewModel.createMode {
    case .terminal:
      terminalLaunchSummaryChipText
    case .codex:
      codexLaunchSummaryChipText
    }
  }

  private var createPaneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Text(viewModel.createMode.headerTitle)
          .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        createModeCard
          .fixedSize(horizontal: true, vertical: false)
      }
      Text(createPaneDescription)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: 620, alignment: .leading)
    }
  }

  private var createModeCard: some View {
    @Bindable var formModel = viewModel
    return Picker("Create", selection: $formModel.createMode) {
      ForEach(AgentTuiCreateMode.allCases) { mode in
        Text(mode.title)
          .tag(mode)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.agentTuiCreateModePicker,
              option: mode.title
            )
          )
          .harnessMCPButton(
            HarnessMonitorAccessibility.segmentedOption(
              HarnessMonitorAccessibility.agentTuiCreateModePicker,
              option: mode.title
            ),
            label: mode.title,
            pressAction: { formModel.createMode = mode }
          )
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .harnessNativeFormControl()
    .harnessMCPButton(
      HarnessMonitorAccessibility.agentTuiCreateModePicker,
      label: "Create"
    )
    .accessibilityLabel("Create")
  }

  func recordCurrentLaunchPreset(mode: LaunchPresetSnapshot.Mode) {
    LaunchPresetDefaults.captureAndWrite(viewModel: viewModel, mode: mode)
  }

  func applySavedLaunchPresetIfFresh() {
    guard let snapshot = LaunchPresetDefaults.read() else { return }
    restoreCreateMode(from: snapshot)
    guard canRestoreSavedLaunchPreset else {
      return
    }
    restoreTerminalLaunchPreset(from: snapshot)
    restoreCodexLaunchPreset(from: snapshot)
  }

  private var canRestoreSavedLaunchPreset: Bool {
    viewModel.prompt.isEmpty
      && viewModel.codexPrompt.isEmpty
      && viewModel.name.isEmpty
      && viewModel.argvOverride.isEmpty
      && viewModel.projectDir.isEmpty
  }

  private func restoreCreateMode(from snapshot: LaunchPresetSnapshot) {
    if let restoredMode = AgentTuiCreateMode(rawValue: snapshot.mode.rawValue) {
      viewModel.createMode = restoredMode
    }
  }

  private func restoreTerminalLaunchPreset(from snapshot: LaunchPresetSnapshot) {
    if !HarnessMonitorAgentLaunchDefaults.hasExplicitPreferredProvider(),
      let providerKey = snapshot.providerStorageKey,
      let parsed = AgentLaunchSelection(storageKey: providerKey)
    {
      let defaultSelection = WorkspaceWindowView.defaultLaunchSelection(
        providerID: HarnessMonitorAgentLaunchDefaults.providerID(for: parsed),
        options: agentCapabilityOptions,
        fallback: parsed
      )
      viewModel.selectedLaunchSelection = defaultSelection
      viewModel.runtime = defaultSelection.preferredRuntime
    }
    if let role = snapshot.role.flatMap(SessionRole.init(rawValue:)) {
      viewModel.selectedRole = role
    }
    if let fallback = snapshot.fallbackRole.flatMap(SessionRole.init(rawValue:)) {
      viewModel.selectedAcpFallbackRole = fallback
    }
    if let personaID = snapshot.personaID, !personaID.isEmpty {
      viewModel.selectedPersona = personaID
    }
    applyRestoredRuntimeSelection(
      snapshot.modelByRuntime,
      to: \.selectedTerminalModelByRuntime
    )
    applyRestoredRuntimeSelection(
      snapshot.customModelByRuntime,
      to: \.customTerminalModelByRuntime
    )
    applyRestoredRuntimeSelection(
      snapshot.effortByRuntime,
      to: \.selectedTerminalEffortByRuntime
    )
    viewModel.rows = snapshot.rows
    viewModel.cols = snapshot.cols
  }

  private func restoreCodexLaunchPreset(from snapshot: LaunchPresetSnapshot) {
    if let codexMode = snapshot.codexMode.flatMap(CodexRunMode.init(rawValue:)) {
      viewModel.codexMode = codexMode
    }
    viewModel.selectedCodexModel = snapshot.codexModel
    viewModel.customCodexModel = snapshot.customCodexModel
    viewModel.selectedCodexEffort = snapshot.codexEffort
  }

  private func applyRestoredRuntimeSelection(
    _ valuesByRuntime: [String: String],
    to keyPath: ReferenceWritableKeyPath<ViewModel, [AgentTuiRuntime: String]>
  ) {
    let restoredValues = valuesByRuntime.reduce(into: [AgentTuiRuntime: String]()) { result, pair in
      guard let runtime = AgentTuiRuntime(rawValue: pair.key) else {
        return
      }
      result[runtime] = pair.value
    }
    if !restoredValues.isEmpty {
      viewModel[keyPath: keyPath] = restoredValues
    }
  }

}
