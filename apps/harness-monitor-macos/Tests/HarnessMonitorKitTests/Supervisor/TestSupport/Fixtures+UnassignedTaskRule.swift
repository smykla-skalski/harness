import Foundation

@testable import HarnessMonitorKit

/// Fixture factories used by `UnassignedTaskRuleTests`. Kept in a worker-local extension so
/// Phase 2 rule workers do not fight over `Fixtures.swift` during parallel execution.
extension Fixtures {
  static func agent(
    id: String,
    runtime: String = "claude",
    statusRaw: String,
    lastActivityAt: Date? = nil,
    idleSeconds: Int? = nil,
    currentTaskID: String? = nil
  ) -> AgentSnapshot {
    AgentSnapshot(
      id: id,
      runtime: runtime,
      statusRaw: statusRaw,
      lastActivityAt: lastActivityAt,
      idleSeconds: idleSeconds,
      currentTaskID: currentTaskID
    )
  }

  static func task(
    id: String,
    statusRaw: String,
    assignedAgentID: String? = nil,
    createdAt: Date,
    severityRaw: String = "normal"
  ) -> TaskSnapshot {
    TaskSnapshot(
      id: id,
      statusRaw: statusRaw,
      assignedAgentID: assignedAgentID,
      createdAt: createdAt,
      severityRaw: severityRaw
    )
  }

  static func session(
    id: String,
    title: String? = nil,
    agents: [AgentSnapshot] = [],
    tasks: [TaskSnapshot] = [],
    timelineDensityLastMinute: Int = 0,
    observerIssues: [ObserverIssueSnapshot] = [],
    pendingCodexApprovals: [CodexApprovalSnapshot] = []
  ) -> SessionSnapshot {
    SessionSnapshot(
      id: id,
      title: title,
      agents: agents,
      tasks: tasks,
      timelineDensityLastMinute: timelineDensityLastMinute,
      observerIssues: observerIssues,
      pendingCodexApprovals: pendingCodexApprovals
    )
  }

  static func snapshot(
    id: String = "snap-1",
    createdAt: Date = .fixed,
    hash: String = "",
    sessions: [SessionSnapshot] = [],
    connection: ConnectionSnapshot = ConnectionSnapshot(
      kind: "connected",
      lastMessageAt: nil,
      reconnectAttempt: 0
    )
  ) -> SessionsSnapshot {
    SessionsSnapshot(
      id: id,
      createdAt: createdAt,
      hash: hash,
      sessions: sessions,
      connection: connection
    )
  }
}
