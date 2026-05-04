import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var createPane: some View {
    WorkspaceWindowCreatePane(
      store: store,
      viewModel: viewModel,
      displayState: displayState,
      focusedFieldBinding: focusedFieldBinding,
      primaryContentFocusScope: currentPrimaryContentFocusScope,
      primaryContentPagingResponderRequest: currentPrimaryContentPagingRequest,
      prefersPrimaryContentFocus: currentPrimaryContentFocusTarget == .create,
      primaryContentFocusParticipationEnabled:
        currentPrimaryContentFocusTarget == .create
        && isWorkspaceKeyWindow
        && focusedField == nil
        && store.presentedSheet == nil
        && store.pendingConfirmation == nil
        && !showsDismissAllVisibleConfirmation,
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

  let store: HarnessMonitorStore
  let viewModel: ViewModel
  let displayState: DisplayState
  let focusedFieldBinding: FocusState<Field?>.Binding
  let primaryContentFocusScope: Namespace.ID?
  let primaryContentPagingResponderRequest: Int
  let prefersPrimaryContentFocus: Bool
  let primaryContentFocusParticipationEnabled: Bool
  let startAction: () -> Void

  var body: some View {
    let activePrimaryContentFocusScope =
      primaryContentFocusParticipationEnabled ? primaryContentFocusScope : nil
    let activePrimaryContentPagingRequest =
      primaryContentFocusParticipationEnabled ? primaryContentPagingResponderRequest : 0
    HarnessMonitorColumnScrollView(
      horizontalPadding: HarnessMonitorTheme.spacingLG,
      verticalPadding: HarnessMonitorTheme.spacingLG,
      constrainContentWidth: false,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.agentTuiLaunchPane,
      scrollSurfaceLabel: "New agent pane",
      primaryFocusScope: activePrimaryContentFocusScope,
      prefersDefaultFocus:
        prefersPrimaryContentFocus && primaryContentFocusParticipationEnabled,
      pagingResponderRequest: activePrimaryContentPagingRequest,
      pagingResponderEnabled: primaryContentFocusParticipationEnabled
    ) {
      // Keep MCP-tracked controls instantiated even while this pane scrolls.
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        createPaneHeader
        createModeCard

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
    .background(.ultraThinMaterial)
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
      Text(viewModel.createMode.headerTitle)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
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
    guard
      viewModel.prompt.isEmpty,
      viewModel.codexPrompt.isEmpty,
      viewModel.name.isEmpty,
      viewModel.argvOverride.isEmpty,
      viewModel.projectDir.isEmpty
    else {
      return
    }
    guard let snapshot = LaunchPresetDefaults.read() else { return }
    if let providerKey = snapshot.providerStorageKey,
      let parsed = AgentLaunchSelection(storageKey: providerKey)
    {
      viewModel.selectedLaunchSelection = parsed
      viewModel.runtime = parsed.preferredRuntime
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
    var restoredModels: [AgentTuiRuntime: String] = [:]
    for (rawKey, value) in snapshot.modelByRuntime {
      if let runtime = AgentTuiRuntime(rawValue: rawKey) {
        restoredModels[runtime] = value
      }
    }
    if !restoredModels.isEmpty {
      viewModel.selectedTerminalModelByRuntime = restoredModels
    }
    var restoredCustom: [AgentTuiRuntime: String] = [:]
    for (rawKey, value) in snapshot.customModelByRuntime {
      if let runtime = AgentTuiRuntime(rawValue: rawKey) {
        restoredCustom[runtime] = value
      }
    }
    if !restoredCustom.isEmpty {
      viewModel.customTerminalModelByRuntime = restoredCustom
    }
    var restoredEffort: [AgentTuiRuntime: String] = [:]
    for (rawKey, value) in snapshot.effortByRuntime {
      if let runtime = AgentTuiRuntime(rawValue: rawKey) {
        restoredEffort[runtime] = value
      }
    }
    if !restoredEffort.isEmpty {
      viewModel.selectedTerminalEffortByRuntime = restoredEffort
    }
    viewModel.rows = snapshot.rows
    viewModel.cols = snapshot.cols
    if let codexMode = snapshot.codexMode.flatMap(CodexRunMode.init(rawValue:)) {
      viewModel.codexMode = codexMode
    }
    viewModel.selectedCodexModel = snapshot.codexModel
    viewModel.customCodexModel = snapshot.customCodexModel
    viewModel.selectedCodexEffort = snapshot.codexEffort
  }

  @ViewBuilder
  func createPaneColumns<Leading: View, Trailing: View>(
    leadingMaxWidth: CGFloat? = nil,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    let leadingView = leading()
    let trailingView = trailing()
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
        leadingView
          .frame(maxWidth: leadingMaxWidth, alignment: .leading)
        trailingView
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        leadingView
          .frame(maxWidth: leadingMaxWidth, alignment: .leading)
        trailingView
      }
    }
  }

}
