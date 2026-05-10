import HarnessMonitorKit
import SwiftUI

struct SessionAgentDetailSectionMetrics: Equatable {
  let sectionSpacing: CGFloat
  let sectionPadding: CGFloat
  let headerSpacing: CGFloat
  let terminalRowSpacing: CGFloat
  let terminalPadding: CGFloat
  let terminalCornerRadius: CGFloat
  let composerSpacing: CGFloat
  let keyStackSpacing: CGFloat
  let keyButtonWidth: CGFloat
  let controlButtonMinSize: CGFloat
  let composerMinHeight: CGFloat
  let composerMaxHeight: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    sectionSpacing = 12 * min(scale, 1.35)
    sectionPadding = 20 * min(scale, 1.25)
    headerSpacing = 4 * min(scale, 1.4)
    terminalRowSpacing = 2 * min(scale, 1.35)
    terminalPadding = 12 * min(scale, 1.35)
    terminalCornerRadius = 8 * min(scale, 1.2)
    composerSpacing = 8 * min(scale, 1.35)
    keyStackSpacing = 6 * min(scale, 1.35)
    keyButtonWidth = max(22, 22 * min(scale, 1.3))
    controlButtonMinSize = scale >= 1.45 ? 44 : 0
    composerMinHeight = max(46, 46 * min(scale, 1.35))
    composerMaxHeight = max(120, 120 * min(scale, 1.2))
  }
}

struct SessionAgentOutputAnnouncementGate: Equatable {
  static let minimumInterval: TimeInterval = 0.1

  private var lastAnnouncementAt = Date.distantPast

  mutating func shouldAnnounce(output: String, now: Date = Date()) -> Bool {
    guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    guard now.timeIntervalSince(lastAnnouncementAt) >= Self.minimumInterval else { return false }
    lastAnnouncementAt = now
    return true
  }
}

enum SessionAgentComposerFocusPolicy {
  static func shouldPromoteComposerFocus(
    requestID: Int,
    isTuiActive: Bool
  ) -> Bool {
    requestID > 0 && isTuiActive
  }
}

struct SessionAgentDetailSection: View {
  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessMonitorStore
  let sessionID: String
  let detail: SessionDetail
  let agentTimeline: [TimelineEntry]
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

  private func computeLatestOutput() -> String {
    let rows = tui?.screen.visibleRows(maxRows: 1) ?? []
    return rows.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
  }

  private var canSendInput: Bool {
    isTuiActive && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var isTuiActive: Bool {
    tui?.status.isActive == true
  }

  private var metrics: SessionAgentDetailSectionMetrics {
    SessionAgentDetailSectionMetrics(fontScale: fontScale)
  }

  private var leaderID: String? {
    detail.session.leaderId
  }

  private var hasRealLeader: Bool {
    Self.hasRealLeader(leaderID: leaderID, agents: detail.agents)
  }

  private var isLeader: Bool {
    agent.agentId == leaderID
  }

  private var roleStateKey: String {
    "\(agent.agentId)|\(agent.role.rawValue)|\(leaderID ?? "-")"
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

  private var rolePickerValues: [SessionRole] {
    AgentDetailSection.rolePickerOptions(for: agent.role)
  }

  private var sessionActionUnavailableMessage: String? {
    store.sessionActionUnavailableMessage(sessionID: sessionID)
  }

  private var actionActorID: String? {
    Self.resolvedActionActorID(
      preferredActorID: store.actionActorID,
      agents: detail.agents,
      leaderID: leaderID
    )
  }

  private var signalActionUnavailableMessage: String? {
    sessionActionUnavailableMessage
      ?? (actionActorID == nil ? Self.noAvailableActionActorMessage : nil)
  }

  private var roleActionsAvailable: Bool {
    sessionActionUnavailableMessage == nil && hasRealLeader && actionActorID != nil
  }

  private var activity: AgentToolActivitySummary? {
    detail.agentActivity.first(where: { $0.agentId == agent.agentId })
  }

  private var overviewFacts: [AgentDetailFact] {
    [
      .init(title: "Last Activity", value: formatTimestamp(agent.lastActivityAt)),
      .init(
        title: "Pickup Time",
        value: "\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s typical"
      ),
    ]
  }

  private var runtimeLaneFacts: [AgentDetailFact] {
    [
      .init(
        title: "Transcript",
        value: agent.runtimeCapabilities.supportsNativeTranscript ? "Native" : "Ledger"
      ),
      .init(
        title: "Signal Delivery",
        value: agent.runtimeCapabilities.supportsSignalDelivery ? "Supported" : "Unavailable"
      ),
      .init(
        title: "Context Injection",
        value: agent.runtimeCapabilities.supportsContextInjection
          ? "Supported" : "Unavailable"
      ),
    ]
  }

  private var capabilityValues: [String] {
    agent.capabilities.isEmpty ? ["No declared capabilities"] : agent.capabilities
  }

  private var hookPoints: [HookIntegrationDescriptor] {
    agent.runtimeCapabilities.hookPoints
  }

  private var activityFacts: [AgentDetailFact] {
    guard let activity else {
      return []
    }
    let issueTint =
      activity.toolErrorCount > 0
      ? HarnessMonitorTheme.danger
      : HarnessMonitorTheme.secondaryInk
    return [
      .init(title: "Actions", value: "\(activity.toolInvocationCount)"),
      .init(title: "Results", value: "\(activity.toolResultCount)"),
      .init(
        title: "Issues",
        value: "\(activity.toolErrorCount)",
        tint: issueTint,
        hidesWhenZero: true
      ),
      .init(title: "Latest Action", value: activity.latestToolName ?? "None"),
    ]
  }

  private var assignedTasks: [WorkItem] {
    detail.tasks.filter { $0.assignedTo == agent.agentId }
  }

  private var currentTaskTitle: String {
    guard
      let currentTaskID = agent.currentTaskId,
      let task = detail.tasks.first(where: { $0.taskId == currentTaskID })
    else {
      return agent.currentTaskId ?? "Idle"
    }
    return task.title
  }

  private var agentTimelineEntries: [TimelineEntry] {
    Self.transcriptEntries(
      agent: agent,
      agentTimeline: agentTimeline,
      acpTranscript: store.acpTranscript(forAgent: agent.agentId, sessionID: sessionID)
    )
  }

  private var isSparseState: Bool {
    agentTimelineEntries.isEmpty && agent.persona == nil && assignedTasks.isEmpty
  }

  private var pendingDecisionAttention: AcpDecisionAttention? {
    store.acpDecisionAttention(for: agent.agentId, sessionID: sessionID)
  }

  private var acpRuntimeState: AcpAgentRuntimeState? {
    store.acpRuntimeState(
      for: agent.agentId,
      sessionID: sessionID,
      sessionRegistrations: detail.agents
    )
  }

  private var acpRuntimeInspectStatus: AcpRuntimeInspectStatus? {
    store.acpRuntimeInspectStatus(
      for: agent.agentId,
      sessionID: sessionID,
      sessionRegistrations: detail.agents
    )
  }

  private var showsTerminalBand: Bool {
    agent.managedAgent?.kind == .tui || tui != nil || pendingPrompt != nil
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
    .onChange(of: tui?.screen.text ?? "") { _, _ in
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
      status: agent.status,
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
    let oldestOpenDecisionID = store.supervisorOpenDecisions
      .filter { $0.sessionID == sessionID && $0.agentID == agent.agentId }
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

  nonisolated static let noAvailableActionActorMessage =
    "No session actor is available yet. Wait for a leader or active agent to join, then try again."

  nonisolated static func draftCommandKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).command"
  }

  nonisolated static func draftMessageKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).message"
  }

  nonisolated static func draftActionHintKey(sessionID: String, agentID: String) -> String {
    "harness.session.agentDraft.\(sessionID).\(agentID).actionHint"
  }

  nonisolated static func transcriptEntries(
    agent: AgentRegistration,
    agentTimeline: [TimelineEntry],
    acpTranscript: [TimelineEntry]
  ) -> [TimelineEntry] {
    if agent.runtimeCapabilities.supportsNativeTranscript, !acpTranscript.isEmpty {
      return acpTranscript
    }
    return agentTimeline
  }

  nonisolated static func resolvedActionActorID(
    preferredActorID: String?,
    agents: [AgentRegistration],
    leaderID: String?
  ) -> String? {
    if let preferredActorID, agents.contains(where: { $0.agentId == preferredActorID }) {
      return preferredActorID
    }
    if let leaderID, agents.contains(where: { $0.agentId == leaderID }) {
      return leaderID
    }
    return agents.first(where: { $0.status == .active })?.agentId
  }

  nonisolated static func hasRealLeader(
    leaderID: String?,
    agents: [AgentRegistration]
  ) -> Bool {
    guard let leaderID else {
      return false
    }
    return agents.contains(where: { $0.agentId == leaderID })
  }
}
