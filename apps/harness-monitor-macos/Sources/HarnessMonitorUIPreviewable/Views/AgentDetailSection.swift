import HarnessMonitorKit
import SwiftUI

// Intentional monolith: this view is the agent detail pane's layout root.
// It concatenates the sections that all key off one agent and share the
// parent's transport state (awaiting-decision strip, runtime card, identity
// strip, fact grid, capability columns, hook points, persona / assigned
// tasks, live transcript, role actions, send update composer).
// Decompose-on-touch: the next change that adds >20 lines or new @State /
// @AppStorage to a section extracts that section into a file-private view
// in the same file (or a sibling file in this directory) before merge.
// If a section is already large enough to merit its own file at the time
// of the next touch, prefer the sibling file over more nested types here.
struct AgentDetailSection: View {
  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessMonitorStore
  let agent: AgentRegistration
  let activity: AgentToolActivitySummary?
  let runtimePresentation: AcpRuntimePresentation
  @State private var selectedSendAction: SendUpdateAction = .injectContext
  @State private var signalCommand = "inject_context"
  @State private var signalMessage = ""
  @State private var signalActionHint = ""
  @State private var selectedRole: SessionRole = .worker
  @State private var transcriptAnnouncer = MonitorTimelineLiveRegionThrottle()
  @State private var lastAnnouncedTimelineEntryId: String?

  init(
    store: HarnessMonitorStore,
    agent: AgentRegistration,
    activity: AgentToolActivitySummary?,
    runtimePresentation: AcpRuntimePresentation = .full
  ) {
    self.store = store
    self.agent = agent
    self.activity = activity
    self.runtimePresentation = runtimePresentation
  }

  private var sessionID: String { store.selectedSessionID ?? "" }
  private var leaderID: String? { store.selectedSession?.session.leaderId }
  private var isLeader: Bool { agent.agentId == leaderID }
  private var roleActionsAvailable: Bool { store.areSelectedLeaderActionsAvailable }
  private var roleStateKey: String {
    "\(agent.agentId)|\(agent.role.rawValue)|\(leaderID ?? "-")"
  }
  private var rolePickerSelection: Binding<SessionRole> {
    Binding(
      get: {
        Self.normalizedRoleSelection(
          draftRole: selectedRole,
          agentRole: agent.role
        )
      },
      set: { selectedRole = $0 }
    )
  }
  private var rolePickerValues: [SessionRole] {
    Self.rolePickerOptions(for: agent.role)
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

  private var runtimeProfileFacts: [AgentDetailFact] {
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
      .init(
        title: "Actions",
        value: "\(activity.toolInvocationCount)"
      ),
      .init(
        title: "Results",
        value: "\(activity.toolResultCount)"
      ),
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
    (store.selectedSession?.tasks ?? []).filter { $0.assignedTo == agent.agentId }
  }

  private var currentTaskTitle: String {
    guard
      let currentTaskID = agent.currentTaskId,
      let task = store.selectedSession?.tasks.first(where: { $0.taskId == currentTaskID })
    else {
      return agent.currentTaskId ?? "Idle"
    }
    return task.title
  }

  private var isSparseState: Bool {
    agentTimelineEntries.isEmpty && agent.persona == nil && assignedTasks.isEmpty
  }

  private var agentTimelineEntries: [TimelineEntry] {
    Self.transcriptEntries(store: store, agent: agent)
  }

  private var pendingDecisionAttention: AcpDecisionAttention? {
    store.acpDecisionAttention(for: agent.agentId)
  }

  private var acpRuntimeState: AcpAgentRuntimeState? {
    store.acpRuntimeState(for: agent.agentId)
  }

  private var acpRuntimeInspectStatus: AcpRuntimeInspectStatus? {
    store.acpRuntimeInspectStatus(for: agent.agentId)
  }

  static func transcriptEntries(
    store: HarnessMonitorStore,
    agent: AgentRegistration
  ) -> [TimelineEntry] {
    if agent.runtimeCapabilities.supportsNativeTranscript {
      return store.acpTranscript(forAgent: agent.agentId)
    }
    return store.timeline(forAgent: agent.agentId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      if let pendingDecisionAttention {
        AgentDetailAwaitingDecisionStrip(
          payload: store.acpPermissionDecisionPayload(
            for: pendingDecisionAttention.oldestDecisionID
          ),
          count: pendingDecisionAttention.count,
          isResolving:
            store.resolvingAcpPermissionBatchID == pendingDecisionAttention.oldestBatchID,
          approveButtonAccessibilityIdentifier:
            HarnessMonitorAccessibility
            .agentDetailApproveDecisionButton(agent.agentId),
          denyButtonAccessibilityIdentifier:
            HarnessMonitorAccessibility
            .agentDetailDenyDecisionButton(agent.agentId),
          viewAllButtonAccessibilityIdentifier:
            HarnessMonitorAccessibility
            .agentDetailOpenDecisionsButton(agent.agentId),
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agent.agentId)
        )
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.agentDetailAwaitingDecisionStrip(agent.agentId),
          label: "Awaiting decision",
          value:
            "count=\(pendingDecisionAttention.count) batch=\(pendingDecisionAttention.oldestBatchID)"
        )
        .accessibilityTestProbe(
          HarnessMonitorAccessibility.workspaceDetailAwaitingDecisionState,
          label:
            "count=\(pendingDecisionAttention.count) batch=\(pendingDecisionAttention.oldestBatchID)",
          value: agent.agentId
        )
      }
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
        runtimePresentation: runtimePresentation
      )
      AgentDetailActivityBand(
        store: store,
        agentID: agent.agentId,
        timeline: agentTimelineEntries,
        runtimeProfileFacts: runtimeProfileFacts,
        capabilityValues: capabilityValues,
        hookPoints: hookPoints,
        activityFacts: activityFacts,
        recentToolValues: activity?.recentTools ?? [],
        persona: agent.persona,
        assignedTasks: assignedTasks,
        prefersWideLayout: runtimePresentation == .full,
        isSparseState: isSparseState
      )
      AgentDetailActionBand(
        store: store,
        sessionID: store.selectedSessionID ?? "",
        agentID: agent.agentId,
        isLeader: isLeader,
        roleActionsAvailable: roleActionsAvailable,
        rolePickerValues: rolePickerValues,
        rolePickerSelection: rolePickerSelection,
        selectedSendAction: $selectedSendAction,
        signalCommand: $signalCommand,
        signalMessage: $signalMessage,
        signalActionHint: $signalActionHint,
        prefersWideLayout: runtimePresentation == .full
      )
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
        await Self.debouncePersist(
          value: signalCommand,
          key: Self.draftCommandKey(agentID: agent.agentId)
        )
      }
      .task(id: signalMessage) {
        await Self.debouncePersist(
          value: signalMessage,
          key: Self.draftMessageKey(agentID: agent.agentId)
        )
      }
      .task(id: signalActionHint) {
        await Self.debouncePersist(
          value: signalActionHint,
          key: Self.draftActionHintKey(agentID: agent.agentId)
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: agent.agentId) {
      hydrateDraft()
      lastAnnouncedTimelineEntryId = agentTimelineEntries.last?.entryId
    }
    .onChange(of: store.timeline.count) { _, _ in
      announceLatestTimelineEntryIfNeeded()
    }
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.workspaceDetailCard,
      label: agent.name,
      value: agent.agentId
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.workspaceDetailCard).frame")
  }

  static func draftCommandKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).command"
  }

  static func draftMessageKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).message"
  }

  static func draftActionHintKey(agentID: String) -> String {
    "harness.workspace.agentDraft.\(agentID).actionHint"
  }

  private func announceLatestTimelineEntryIfNeeded() {
    guard let entry = agentTimelineEntries.last else { return }
    guard entry.entryId != lastAnnouncedTimelineEntryId else { return }
    lastAnnouncedTimelineEntryId = entry.entryId
    let priority = MonitorTimelineLiveRegion.priority(for: entry.kind)
    transcriptAnnouncer.announceIfAllowed(entry.summary, priority: priority)
  }

  static func debouncePersist(value: String, key: String) async {
    do {
      try await Task.sleep(for: .milliseconds(300))
    } catch {
      return
    }
    UserDefaults.standard.set(value, forKey: key)
  }

  private func hydrateDraft() {
    let defaults = UserDefaults.standard
    let savedCommand = defaults.string(forKey: Self.draftCommandKey(agentID: agent.agentId)) ?? ""
    let savedMessage = defaults.string(forKey: Self.draftMessageKey(agentID: agent.agentId)) ?? ""
    let savedActionHint =
      defaults.string(forKey: Self.draftActionHintKey(agentID: agent.agentId)) ?? ""
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

  @ViewBuilder
  private func runtimeView(
    runtimeState: AcpAgentRuntimeState,
    inspectStatus: AcpRuntimeInspectStatus
  ) -> some View {
    AcpRuntimeView(
      store: store,
      runtimeState: runtimeState,
      inspectStatus: inspectStatus,
      presentation: runtimePresentation
    )
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
      .filter { $0.agentID == agent.agentId }
      .min {
        if $0.createdAt != $1.createdAt {
          return $0.createdAt < $1.createdAt
        }
        return $0.id < $1.id
      }?.id

    if let decisionID = oldestOpenDecisionID ?? store.selectOldestDecision(for: agent.agentId) {
      store.requestWorkspaceDecisionSelection(decisionID: decisionID)
      store.supervisorSelectedDecisionID = decisionID
      store.requestPrimaryDecisionActionFocus(decisionID: decisionID)
    }
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  static func humanizedHookLabel(for hook: HookIntegrationDescriptor) -> String {
    let trigger: String
    switch hook.name {
    case "BeforeTool":
      trigger = "before each tool call"
    case "AfterTool":
      trigger = "after each tool call"
    case "BeforePrompt":
      trigger = "before each prompt"
    case "AfterPrompt":
      trigger = "after each prompt"
    default:
      trigger = "on \(hook.name)"
    }
    let contextMode =
      hook.supportsContextInjection ? "with context injection" : "no context"
    let contextSuffix = " (\(contextMode))"
    return "Runs \(hook.typicalLatencySeconds)s \(trigger)\(contextSuffix)"
  }

  private func humanizedHookLabel(for hook: HookIntegrationDescriptor) -> String {
    Self.humanizedHookLabel(for: hook)
  }

}
