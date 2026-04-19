import AppKit
import HarnessMonitorKit
import SwiftUI

extension AgentTuiWindowView {
  @ViewBuilder var detailColumnContent: some View {
    if usesLiveViewportSplitLayout, let selectedSessionTui {
      sessionPane(selectedSessionTui)
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(scrollContainerIdentity)
    } else if case .create = viewModel.selection {
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

  @ViewBuilder var paneContent: some View {
    switch viewModel.selection {
    case .create:
      createPane
    case .terminal:
      if let selectedSessionTui {
        sessionPane(selectedSessionTui)
      } else {
        unavailableSessionPane
      }
    case .codex:
      if let selectedCodexRun {
        codexPane(selectedCodexRun)
      } else {
        unavailableSessionPane
      }
    }
  }

  var createPaneDescription: String {
    switch viewModel.createMode {
    case .terminal:
      if viewModel.displayState.hasAgentTuis {
        "Open terminal-backed agents stay pinned in the sidebar so you can launch "
          + "another agent without losing the active viewport."
      } else {
        "Start a terminal-backed agent to inspect the live screen and steer it from Harness Monitor."
      }
    case .codex:
      if viewModel.displayState.hasCodexRuns {
        "Codex threads stay pinned in the sidebar so you can continue active work without losing context."
      } else {
        "Start a Codex thread to investigate, patch, or route approvals from the same Agents window."
      }
    }
  }

  var createPane: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if viewModel.createMode == .terminal && viewModel.displayState.agentTuiUnavailable {
        agentTuiUnavailableBanner
      }
      if viewModel.createMode == .codex && viewModel.displayState.codexUnavailable {
        codexUnavailableBanner
      }
      launchSection
      Text(createPaneDescription)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiLaunchPane)
  }

  var unavailableSessionPane: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("That agent entry is no longer available.")
        .scaledFont(.headline)
      Button("Back to create") {
        selectCreateTab()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiBackToCreateButton)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  var launchSection: some View {
    launchForm
  }

  var launchForm: some View {
    @Bindable var formModel = viewModel
    return VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("New agent")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Picker("Mode", selection: $formModel.createMode) {
        ForEach(AgentTuiCreateMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        switch formModel.createMode {
        case .terminal:
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            Picker("Runtime", selection: $formModel.runtime) {
              ForEach(AgentTuiRuntime.allCases) { runtime in
                Text(runtime.title).tag(runtime)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiRuntimePicker)
            if !formModel.availablePersonas.isEmpty {
              inlinePersonaGrid
            }
            TextField("Optional display name", text: $formModel.name)
              .harnessNativeFormControl()
              .focused(focusedFieldBinding, equals: .name)
              .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNameField)
            multilineEditor(
              placeholder: "Optional first prompt to submit inside the terminal agent",
              text: $formModel.prompt,
              field: .prompt,
              minHeight: 72,
              accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiPromptField
            )
            TextField("Optional project directory override", text: $formModel.projectDir)
              .harnessNativeFormControl()
              .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiProjectDirField)
            multilineEditor(
              placeholder:
                "Optional argv override (one argument per line; first line is the executable)",
              text: $formModel.argvOverride,
              field: .argv,
              minHeight: 88,
              accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiArgvField
            )
          }

          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            Text("Terminal size")
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            Stepper(
              "Rows \(formModel.rows)",
              value: $formModel.rows,
              in: TerminalViewportSizing.rowRange
            )
            Stepper(
              "Cols \(formModel.cols)",
              value: $formModel.cols,
              in: TerminalViewportSizing.colRange,
              step: 10
            )
            Spacer(minLength: 0)
            HarnessMonitorActionButton(
              title: "Start \(formModel.runtime.title)",
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.agentTuiStartButton,
              fillsWidth: true
            ) {
              startTui()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canStartTerminal)
            .accessibilityTestProbe(
              HarnessMonitorAccessibility.agentTuiStartButton,
              label: "Start \(formModel.runtime.title)"
            )
          }
          .frame(width: 240, alignment: .topLeading)

        case .codex:
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            Text("Prompt")
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            multilineEditor(
              placeholder: "Ask Codex to investigate or patch this session",
              text: $formModel.codexPrompt,
              field: .prompt,
              minHeight: 120,
              accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexPromptField
            )
            Picker("Mode", selection: $formModel.codexMode) {
              ForEach(CodexRunMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexModePicker)
          }

          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            Text("Codex thread")
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            Text("Use report for investigation, workspace write for direct patches, and approval for gated edits.")
              .scaledFont(.footnote)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HarnessMonitorActionButton(
              title: "Start Codex",
              variant: .prominent,
              accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexSubmitButton,
              fillsWidth: true
            ) {
              startTui()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canStartCodex)
            .accessibilityTestProbe(
              HarnessMonitorAccessibility.agentsCodexSubmitButton,
              label: "Start Codex"
            )
          }
          .frame(width: 260, alignment: .topLeading)
        }
      }
    }
  }

  static let personaColumns = [
    GridItem(.adaptive(minimum: 140), spacing: HarnessMonitorTheme.spacingMD)
  ]

  var inlinePersonaGrid: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Persona")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      LazyVGrid(columns: Self.personaColumns, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(viewModel.availablePersonas, id: \.identifier) { persona in
          personaCardButton(persona)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiPersonaPicker)
  }

  func personaCardButton(_ persona: AgentPersona) -> some View {
    let isSelected = viewModel.selectedPersona == persona.identifier
    return Button {
      viewModel.selectedPersona = isSelected ? nil : persona.identifier
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
        get: { viewModel.expandedPersonaInfo == persona.identifier },
        set: { if !$0 { viewModel.expandedPersonaInfo = nil } }
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
        viewModel.expandedPersonaInfo = persona.identifier
      }
    }
  }

  func sessionPane(_ tui: AgentTuiSnapshot) -> some View {
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

  func codexPane(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      codexHeader(run)
      if let finalMessage = run.finalMessage, !finalMessage.isEmpty {
        codexTextSection(title: "Final", text: finalMessage)
      } else if let latestSummary = run.latestSummary, !latestSummary.isEmpty {
        codexTextSection(title: "Latest", text: latestSummary)
      }
      if let error = run.error, !error.isEmpty {
        codexTextSection(title: "Error", text: error)
          .foregroundStyle(HarnessMonitorTheme.danger)
      }
      if !run.pendingApprovals.isEmpty {
        codexApprovalsSection(run)
      }
      if run.status.isActive {
        codexContextSection(run)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  func liveSessionLayout(_ tui: AgentTuiSnapshot) -> some View {
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

  func liveSessionControls(_ tui: AgentTuiSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      if let error = tui.error, !error.isEmpty {
        terminalError(error)
      }
      terminalInputControls(tui)
      terminalKeyControls(tui)
      terminalResizeControls()
    }
  }

  func codexHeader(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(resolvedTitle(for: run))
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      HStack(alignment: .firstTextBaseline) {
        Text(run.status.title)
          .scaledFont(.caption.monospacedDigit())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        if run.status.isActive {
          Button("Interrupt") {
            interruptCodexRun(run)
          }
          .harnessActionButtonStyle(variant: .bordered, tint: nil)
          .disabled(viewModel.isSubmitting)
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexInterruptButton)
        }
      }
    }
  }

  func codexTextSection(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
      Text(text)
        .scaledFont(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  func codexApprovalsSection(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Approvals")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ForEach(run.pendingApprovals) { approval in
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Text(approval.title)
            .scaledFont(.headline)
          Text(approval.detail)
            .scaledFont(.subheadline)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .textSelection(.enabled)
          HStack {
            codexApprovalButton("Approve", approval: approval, run: run, decision: .accept)
            codexApprovalButton(
              "Allow Session",
              approval: approval,
              run: run,
              decision: .acceptForSession
            )
            codexApprovalButton("Decline", approval: approval, run: run, decision: .decline)
            Spacer()
            codexApprovalButton("Cancel", approval: approval, run: run, decision: .cancel)
          }
        }
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
      }
    }
  }

  func codexApprovalButton(
    _ title: String,
    approval: CodexApprovalRequest,
    run: CodexRunSnapshot,
    decision: CodexApprovalDecision
  ) -> some View {
    Button(title) {
      resolveCodexApproval(approval, run: run, decision: decision)
    }
    .disabled(viewModel.resolvingCodexApprovalID != nil || viewModel.isSubmitting)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.codexApprovalButton(
        approval.approvalId,
        decision: decision.rawValue
      )
    )
  }

  func codexContextSection(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("New Context")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      multilineEditor(
        placeholder: "Add context to the active Codex turn",
        text: Binding(get: { viewModel.codexContext }, set: { viewModel.codexContext = $0 }),
        field: .input,
        minHeight: 88,
        accessibilityIdentifier: HarnessMonitorAccessibility.agentsCodexContextField
      )
      Button("Send Context") {
        steerCodexRun(run)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: nil)
      .disabled(!canSteerCodex)
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentsCodexSteerButton)
    }
  }

  @ToolbarContentBuilder var agentTuiNavigationToolbarItems: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        navigateHistoryBack()
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(!viewModel.windowNavigation.canGoBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNavigateBackButton)

      Button {
        navigateHistoryForward()
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(!viewModel.windowNavigation.canGoForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiNavigateForwardButton)
    }
  }

  @ToolbarContentBuilder var sessionToolbarItems: some ToolbarContent {
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
          .help("Stop this Agents session")
          .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiStopButton)
        }
      }
    }
  }
}
