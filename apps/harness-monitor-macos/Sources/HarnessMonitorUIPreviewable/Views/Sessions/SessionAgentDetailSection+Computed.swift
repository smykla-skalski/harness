import HarnessMonitorKit
import SwiftUI

extension SessionAgentDetailSection {
  private var hasRealLeader: Bool {
    Self.hasRealLeader(leaderID: leaderID, agents: detail.agents)
  }

  private var isLeader: Bool {
    agent.agentId == leaderID
  }

  private var roleStateKey: String {
    "\(agent.agentId)|\(agent.role.rawValue)|\(leaderID ?? "-")"
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
}
