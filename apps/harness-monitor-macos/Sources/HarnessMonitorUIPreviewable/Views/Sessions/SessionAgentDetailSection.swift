import HarnessMonitorKit
import SwiftUI

struct SessionAgentDetailSection: View {
  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessMonitorStore
  let sessionID: String
  let detail: SessionDetail
  let runtimePresentation: HarnessMonitorStore.AgentRuntimePresentationContext?
  let agentTimeline: [TimelineEntry]
  let agentTranscript: [TimelineEntry]
  let agent: AgentRegistration
  let tui: AgentTuiSnapshot?
  let pendingPrompt: AgentPendingUserPrompt?
  let composerFocusRequestID: Int
  @Environment(\.accessibilityVoiceOverEnabled)
  private var voiceOverEnabled
  @Environment(\.fontScale)
  private var fontScale
  @State private var message = ""
  @State private var composerBackdropHeight: CGFloat = 0
  @State private var outputAnnouncementGate = SessionAgentOutputAnnouncementGate()
  @State private var latestOutput = "No output"
  @State private var selectedSendAction: SendUpdateAction = .injectContext
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""
  @State private var selectedRole: SessionRole = .worker
  @State private var transcriptAnnouncer = MonitorTimelineLiveRegionThrottle()
  @State private var lastAnnouncedTimelineEntryId: String?
  @FocusState private var focusedField: SessionAgentComposerField?

  private var canSendInput: Bool {
    isTuiActive && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isTuiActive: Bool {
    tui?.status.isActive == true
  }

  private var metrics: SessionAgentDetailSectionMetrics {
    SessionAgentDetailSectionMetrics(fontScale: fontScale)
  }

  private var rolePickerSelection: Binding<SessionRole> {
    Binding(
      get: {
        AgentDetailSection.normalizedRoleSelection(
          draftRole: selectedRole,
          agentRole: agent.role
        )
      },
      set: { selectedRole = $0 }
    )
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: HarnessMonitorTheme.spacingLG,
      verticalPadding: HarnessMonitorTheme.spacingLG,
      constrainContentWidth: false,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.agentDetailScrollView,
      scrollSurfaceLabel: "Agent detail"
    ) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        awaitingDecisionStripView
        summaryBandView
        if showsTerminalBand {
          terminalBandView
        }
        activityBandView
        actionBandView
      }
      .agentDetailCardProbe(name: agent.name, agentID: agent.agentId)
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      latestOutput = computeLatestOutput()
    }
    .task(id: roleStateKey) {
      selectedRole = agent.role
    }
    .onChange(of: selectedSendAction) { _, newValue in
      if newValue != .custom {
        signalCommand = newValue.rawCommand
      } else if signalCommand == SendUpdateAction.injectContext.rawCommand {
        signalCommand = ""
      }
    }
    .task(id: signalCommand) {
      await AgentDetailSection.debouncePersist(
        value: signalCommand,
        key: Self.draftCommandKey(sessionID: sessionID, agentID: agent.agentId)
      )
    }
    .task(id: signalMessage) {
      await AgentDetailSection.debouncePersist(
        value: signalMessage,
        key: Self.draftMessageKey(sessionID: sessionID, agentID: agent.agentId)
      )
    }
    .task(id: signalActionHint) {
      await AgentDetailSection.debouncePersist(
        value: signalActionHint,
        key: Self.draftActionHintKey(sessionID: sessionID, agentID: agent.agentId)
      )
    }
    .task(id: agent.agentId) {
      hydrateDraft()
      lastAnnouncedTimelineEntryId = agentTimelineEntries.last?.entryId
    }
    .task(id: composerFocusRequestID) {
      promoteComposerFocusIfRequested()
    }
    .onChange(of: isTuiActive) { _, _ in
      promoteComposerFocusIfRequested()
    }
    // Debounce TUI screen-text bursts via .task(id:); each text change
    // cancels the in-flight wait so a burst of bytes collapses into one
    // update once the stream goes quiet for the threshold below.
    .task(id: tui?.screen.text ?? "") {
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled else { return }
      let next = computeLatestOutput()
      guard next != latestOutput else { return }
      latestOutput = next
      announceOutputIfAllowed(next)
    }
    .onChange(of: agentTimelineEntries.last?.entryId) { _, _ in
      announceLatestTimelineEntryIfNeeded()
    }
  }

  @ViewBuilder private var awaitingDecisionStripView: some View {
    if let pendingDecisionAttention {
      AgentDetailAwaitingDecisionRegion(
        agentID: agent.agentId,
        attention: pendingDecisionAttention,
        payload: store.acpPermissionDecisionPayload(
          for: pendingDecisionAttention.oldestDecisionID
        ),
        isResolving:
          store.resolvingAcpPermissionBatchID == pendingDecisionAttention.oldestBatchID,
        onApprove: {
          dispatchPendingDecision(
            attention: pendingDecisionAttention,
            actionID: AcpPermissionDecisionActionID.approveActionID(
              forRequestCount: pendingDecisionAttention.count
            )
          )
        },
        onDeny: {
          dispatchPendingDecision(
            attention: pendingDecisionAttention,
            actionID: AcpPermissionDecisionActionID.denyActionID(
              forRequestCount: pendingDecisionAttention.count
            )
          )
        },
        onViewAll: {
          openPendingDecisions()
        }
      )
    }
  }

  private var summaryBandView: some View {
    AgentDetailSummaryBand(
      store: store,
      title: agent.name,
      runtimeLabel: runtimeDisplayLabel(agent.runtime),
      status: lifecyclePresentation.visualStatus,
      statusLabel: lifecyclePresentation.label,
      roleTitle: agent.role.title,
      currentTaskTitle: currentTaskTitle,
      overviewFacts: overviewFacts,
      runtimeState: acpRuntimeState,
      inspectStatus: acpRuntimeInspectStatus,
      runtimePresentation: .full
    )
  }

  private var activityBandView: some View {
    AgentDetailActivityBand(
      store: store,
      agentID: agent.agentId,
      timeline: agentTimelineEntries,
      runtimeLaneFacts: runtimeLaneFacts,
      capabilityValues: capabilityValues,
      hookPoints: hookPoints,
      activityFacts: activityFacts,
      recentToolValues: activity?.recentTools ?? [],
      persona: agent.persona,
      assignedTasks: assignedTasks,
      prefersWideLayout: true,
      isSparseState: isSparseState
    )
  }

  private var actionBandView: some View {
    AgentDetailActionBand(
      store: store,
      sessionID: sessionID,
      agentID: agent.agentId,
      agentName: agent.name,
      isLeader: isLeader,
      roleActionsAvailable: roleActionsAvailable,
      actionActorID: actionActorID,
      actionUnavailableMessage: signalActionUnavailableMessage,
      rolePickerValues: rolePickerValues,
      runtimeState: acpRuntimeState,
      rolePickerSelection: rolePickerSelection,
      selectedSendAction: $selectedSendAction,
      signalCommand: $signalCommand,
      signalMessage: $signalMessage,
      signalActionHint: $signalActionHint,
      prefersWideLayout: true
    )
  }

  private var terminalBandView: some View {
    AgentDetailPanel(title: "Terminal") {
      VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
        if let error = tui?.error, !error.isEmpty {
          SessionAgentTuiErrorBanner(message: error)
        }
        if let tui, !tui.status.isActive, tui.exitCode != nil || (tui.signal?.isEmpty == false) {
          SessionAgentTuiOutcomeBanner(exitCode: tui.exitCode, signal: tui.signal)
        }
        SessionAgentTuiViewport(
          store: store,
          agentID: agent.agentId,
          tui: tui,
          metrics: metrics,
          latestOutput: latestOutput
        )
        if let pendingPrompt {
          SessionAgentTuiPendingPromptBanner(prompt: pendingPrompt)
        }
        SessionAgentComposer(
          agentID: agent.agentId,
          message: $message,
          focusedField: $focusedField,
          backdropHeight: $composerBackdropHeight,
          metrics: metrics,
          isActive: tui?.status.isActive == true,
          canSendInput: canSendInput,
          sendMessage: { Task { await sendMessage() } },
          sendKey: { key in Task { await sendKey(key) } }
        )
      }
    }
  }

  @MainActor
  private func sendMessage() async {
    guard let tui, canSendInput else { return }
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    message = ""
    _ = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      input: .text("\(text)\n"),
      showSuccessFeedback: false
    )
    AccessibilityNotification.Announcement("Message sent. Waiting for agent reply.").post()
  }

  @MainActor
  private func sendKey(_ key: AgentTuiKey) async {
    guard let tui else { return }
    _ = await store.sendAgentTuiInput(
      tuiID: tui.tuiId,
      input: .key(key),
      showSuccessFeedback: false
    )
  }

  private func announceOutputIfAllowed(_ output: String) {
    guard outputAnnouncementGate.shouldAnnounce(output: output) else { return }
    AccessibilityNotification.Announcement(output).post()
  }

  private func announceLatestTimelineEntryIfNeeded() {
    guard let entry = agentTimelineEntries.last else { return }
    guard entry.entryId != lastAnnouncedTimelineEntryId else { return }
    lastAnnouncedTimelineEntryId = entry.entryId
    let priority = MonitorTimelineLiveRegion.priority(
      for: entry.kind,
      summary: entry.summary
    )
    transcriptAnnouncer.announceIfAllowed(entry.summary, priority: priority)
  }

  private func hydrateDraft() {
    let defaults = UserDefaults.standard
    let savedCommand =
      defaults.string(
        forKey: Self.draftCommandKey(sessionID: sessionID, agentID: agent.agentId)
      ) ?? ""
    let savedMessage =
      defaults.string(
        forKey: Self.draftMessageKey(sessionID: sessionID, agentID: agent.agentId)
      ) ?? ""
    let savedActionHint =
      defaults.string(
        forKey: Self.draftActionHintKey(sessionID: sessionID, agentID: agent.agentId)
      ) ?? ""
    if savedCommand.isEmpty {
      signalCommand = SendUpdateAction.injectContext.rawCommand
      selectedSendAction = .injectContext
    } else {
      signalCommand = savedCommand
      selectedSendAction =
        savedCommand == SendUpdateAction.injectContext.rawCommand
        ? .injectContext : .custom
    }
    signalMessage = savedMessage
    signalActionHint = savedActionHint
  }

  private func dispatchPendingDecision(
    attention: AcpDecisionAttention,
    actionID: String
  ) {
    let decisionID = attention.oldestDecisionID
    Task {
      _ = await store.submitAcpPermissionDecisionAction(
        decisionID: decisionID,
        actionID: actionID
      )
    }
  }

  private func openPendingDecisions() {
    let oldestOpenDecisionID =
      (store.supervisorPresentationItemsBySession[sessionID] ?? [])
      .filter { $0.agentID == agent.agentId }
      .min {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id < $1.id
      }?.id

    if let decisionID = oldestOpenDecisionID ?? pendingDecisionAttention?.oldestDecisionID {
      store.requestSessionRoute(
        .decision(sessionID: sessionID, decisionID: decisionID),
        resetDecisionFilters: true
      )
      store.supervisorSelectedDecisionID = decisionID
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
    } else {
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
    }
  }

  private func promoteComposerFocusIfRequested() {
    guard
      SessionAgentComposerFocusPolicy.shouldPromoteComposerFocus(
        requestID: composerFocusRequestID,
        isTuiActive: isTuiActive
      )
    else {
      return
    }
    if voiceOverEnabled {
      Task { @MainActor in
        await Task.yield()
        focusedField = .composer
      }
    } else {
      focusedField = .composer
    }
  }

}
