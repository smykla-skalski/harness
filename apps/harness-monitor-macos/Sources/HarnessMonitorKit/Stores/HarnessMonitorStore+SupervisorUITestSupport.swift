#if DEBUG
  import Foundation
  import SwiftData

  @MainActor
  public enum HarnessMonitorSupervisorUITestScenario: String {
    case stuckAgent = "stuck-agent"
  }

  @MainActor
  extension HarnessMonitorStore {
    public func seedSupervisorScenarioForTesting(named rawValue: String?) {
      guard
        let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        let scenario = HarnessMonitorSupervisorUITestScenario(rawValue: rawValue)
      else {
        return
      }

      do {
        try applySupervisorUITestScenario(scenario)
      } catch {
        HarnessMonitorLogger.supervisor.warning(
          """
          supervisor.ui_test_seed_failed scenario=\(scenario.rawValue, privacy: .public) \
          error=\(String(describing: error), privacy: .public)
          """
        )
      }
    }

    private func applySupervisorUITestScenario(
      _ scenario: HarnessMonitorSupervisorUITestScenario
    ) throws {
      switch scenario {
      case .stuckAgent:
        try seedStuckAgentSupervisorScenario()
      }
    }

    private func seedStuckAgentSupervisorScenario() throws {
      let now = Date()
      let staleActivity = now.addingTimeInterval(-300)
      let createdAt = now.addingTimeInterval(-3600)
      let summary = SessionSummary(
        projectId: "project-ui-tests",
        projectName: "Harness UI Tests",
        contextRoot: "/tmp/harness-ui-tests",
        sessionId: "session-ui-stuck",
        title: "Supervisor Stuck Agent",
        context: "Supervisor toolbar badge regression fixture",
        status: .active,
        createdAt: iso8601String(createdAt),
        updatedAt: iso8601String(now),
        lastActivityAt: iso8601String(now),
        leaderId: "agent-ui-leader",
        observeId: nil,
        pendingLeaderTransfer: nil,
        metrics: SessionMetrics(
          agentCount: 1,
          activeAgentCount: 1,
          openTaskCount: 1,
          inProgressTaskCount: 1,
          blockedTaskCount: 0,
          completedTaskCount: 0
        )
      )
      let agent = AgentRegistration(
        agentId: "agent-ui-stuck",
        name: "Stuck Worker",
        runtime: "codex",
        role: .worker,
        capabilities: [],
        joinedAt: iso8601String(createdAt),
        updatedAt: iso8601String(now),
        status: .active,
        agentSessionId: nil,
        lastActivityAt: iso8601String(staleActivity),
        currentTaskId: "task-ui-stuck",
        runtimeCapabilities: RuntimeCapabilities(
          runtime: "codex",
          supportsNativeTranscript: true,
          supportsSignalDelivery: true,
          supportsContextInjection: true,
          typicalSignalLatencySeconds: 1,
          hookPoints: []
        ),
        persona: nil
      )
      let task = WorkItem(
        taskId: "task-ui-stuck",
        title: "Unblock the stalled worker",
        context: "Seeded UI-test task for the stuck-agent rule",
        severity: .medium,
        status: .inProgress,
        assignedTo: agent.agentId,
        createdAt: iso8601String(createdAt),
        updatedAt: iso8601String(now),
        createdBy: "ui-tests",
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      )
      let detail = SessionDetail(
        session: summary,
        agents: [agent],
        tasks: [task],
        signals: [],
        observer: nil,
        agentActivity: []
      )

      applySeededSupervisorSession(summary: summary, detail: detail)

      try upsertSupervisorPolicyConfig(
        ruleID: "stuck-agent",
        defaultBehavior: .aggressive,
        parametersJSON: stuckAgentPolicyParametersJSON,
        updatedAt: now
      )
    }

    private func applySeededSupervisorSession(
      summary: SessionSummary,
      detail: SessionDetail
    ) {
      sessionIndex.replaceSnapshot(projects: [], sessions: [summary])
      selectedSessionID = summary.sessionId
      selectedSession = detail
      timeline = []
      selectedCodexRuns = []
      selectedCodexRun = nil
      codexRunsBySessionID = [:]
      connectionState = .online
      activeTransport = .webSocket
    }

    private var stuckAgentPolicyParametersJSON: String {
      """
      {"nudgeMaxRetries":"0","nudgeRetryInterval":"120","stuckThreshold":"120"}
      """
    }

    private func upsertSupervisorPolicyConfig(
      ruleID: String,
      defaultBehavior: RuleDefaultBehavior,
      parametersJSON: String,
      updatedAt: Date
    ) throws {
      guard let modelContext else {
        return
      }

      let descriptor = FetchDescriptor<PolicyConfigRow>(
        predicate: #Predicate { $0.ruleID == ruleID }
      )
      let row =
        try modelContext.fetch(descriptor).first
        ?? {
          let newRow = PolicyConfigRow(
            ruleID: ruleID,
            enabled: true,
            defaultBehavior: defaultBehavior.rawValue,
            parametersJSON: parametersJSON
          )
          modelContext.insert(newRow)
          return newRow
        }()

      row.enabled = true
      row.defaultBehaviorRaw = defaultBehavior.rawValue
      row.parametersJSON = parametersJSON
      row.updatedAt = updatedAt
      try modelContext.save()
    }

    private func iso8601String(_ date: Date) -> String {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.string(from: date)
    }
  }
#endif
