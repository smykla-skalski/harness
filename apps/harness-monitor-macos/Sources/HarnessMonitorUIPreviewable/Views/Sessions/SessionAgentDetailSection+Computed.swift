import HarnessMonitorKit
import SwiftUI

extension SessionAgentDetailSection {
  var hasRealLeader: Bool {
    Self.hasRealLeader(leaderID: leaderID, agents: detail.agents)
  }

  var isLeader: Bool {
    agent.agentId == leaderID
  }

  var roleStateKey: String {
    "\(agent.agentId)|\(agent.role.rawValue)|\(leaderID ?? "-")"
  }

  var rolePickerValues: [SessionRole] {
    AgentDetailSection.rolePickerOptions(for: agent.role)
  }

  var sessionActionUnavailableMessage: String? {
    store.sessionActionUnavailableMessage(sessionID: sessionID)
  }

  var actionActorID: String? {
    Self.resolvedActionActorID(
      preferredActorID: store.actionActorID,
      agents: detail.agents,
      leaderID: leaderID
    )
  }

  var signalActionUnavailableMessage: String? {
    sessionActionUnavailableMessage
      ?? (actionActorID == nil ? Self.noAvailableActionActorMessage : nil)
  }

  var roleActionsAvailable: Bool {
    sessionActionUnavailableMessage == nil && hasRealLeader && actionActorID != nil
  }

  var activity: AgentToolActivitySummary? {
    detail.agentActivity.first(where: { $0.agentId == agent.agentId })
  }

  var overviewFacts: [AgentDetailFact] {
    [
      .init(title: "Last Activity", value: formatTimestamp(agent.lastActivityAt)),
      .init(
        title: "Pickup Time",
        value: "\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s typical"
      ),
    ]
  }

  var runtimeLaneFacts: [AgentDetailFact] {
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

  var capabilityValues: [String] {
    agent.capabilities.isEmpty ? ["No declared capabilities"] : agent.capabilities
  }

  var hookPoints: [HookIntegrationDescriptor] {
    agent.runtimeCapabilities.hookPoints
  }

  var activityFacts: [AgentDetailFact] {
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

  var assignedTasks: [WorkItem] {
    detail.tasks.filter { $0.assignedTo == agent.agentId }
  }

  var currentTaskTitle: String {
    guard
      let currentTaskID = agent.currentTaskId,
      let task = detail.tasks.first(where: { $0.taskId == currentTaskID })
    else {
      return agent.currentTaskId ?? "Idle"
    }
    return task.title
  }

  var agentTimelineEntries: [TimelineEntry] {
    Self.transcriptEntries(
      agent: agent,
      agentTimeline: agentTimeline,
      acpTranscript: store.acpTranscript(forAgent: agent.agentId, sessionID: sessionID)
    )
  }

  var isSparseState: Bool {
    agentTimelineEntries.isEmpty && agent.persona == nil && assignedTasks.isEmpty
  }

  var pendingDecisionAttention: AcpDecisionAttention? {
    store.acpDecisionAttention(for: agent.agentId, sessionID: sessionID)
  }

  var acpRuntimeState: AcpAgentRuntimeState? {
    store.acpRuntimeState(
      for: agent.agentId,
      sessionID: sessionID,
      sessionRegistrations: detail.agents
    )
  }

  var acpRuntimeInspectStatus: AcpRuntimeInspectStatus? {
    store.acpRuntimeInspectStatus(
      for: agent.agentId,
      sessionID: sessionID,
      sessionRegistrations: detail.agents
    )
  }

  var showsTerminalBand: Bool {
    agent.managedAgent?.kind == .tui || tui != nil || pendingPrompt != nil
  }
}
