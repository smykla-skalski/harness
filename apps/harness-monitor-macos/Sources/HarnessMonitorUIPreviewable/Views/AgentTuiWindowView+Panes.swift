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
      createPane
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
    case .agent(let agentID):
      agentDetailPane(agentID: agentID)
    }
  }

  @ViewBuilder
  func agentDetailPane(agentID: String) -> some View {
    if let session = store.selectedSession,
      let agent = session.agents.first(where: { $0.agentId == agentID })
    {
      AgentDetailSection(
        store: store,
        agent: agent,
        activity: session.agentActivity.first(where: { $0.agentId == agentID })
      )
    } else {
      unavailableSessionPane
    }
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.agentTuiSessionPane)
  }

  func codexPane(_ run: CodexRunSnapshot) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      codexHeader(run)
      if let finalMessage = run.finalMessage, !finalMessage.isEmpty {
        codexTextSection(title: "Final", text: finalMessage)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentsCodexFinalMessage,
            label: finalMessage
          )
      } else if let latestSummary = run.latestSummary, !latestSummary.isEmpty {
        codexTextSection(title: "Latest", text: latestSummary)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentsCodexLatestSummary,
            label: latestSummary
          )
      }
      if let error = run.error, !error.isEmpty {
        codexTextSection(title: "Error", text: error)
          .foregroundStyle(HarnessMonitorTheme.danger)
          .accessibilityTestProbe(
            HarnessMonitorAccessibility.agentsCodexErrorMessage,
            label: error
          )
      }
      if !run.pendingApprovals.isEmpty {
        codexApprovalsSection(run)
      }
      if run.status.isActive {
        codexContextSection(run)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
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
      .accessibilityFrameMarker("\(HarnessMonitorAccessibility.agentsCodexSteerButton).frame")
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.agentsCodexSteerButton, label: "Send Context")
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
