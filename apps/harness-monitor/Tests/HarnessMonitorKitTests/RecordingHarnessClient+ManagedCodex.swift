import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func codexInspect(sessionID: String?) async throws -> CodexAgentInspectResponse {
    let sessionIDs =
      sessionID.map {
        [$0]
      }
      ?? lock.withLock {
        Array(codexRunsBySessionID.keys)
      }
    let runs = sessionIDs.flatMap { configuredCodexRuns(for: $0) }
    return CodexAgentInspectResponse(
      agents: runs.map { run in
        CodexAgentInspectSnapshot(
          runId: run.runId,
          sessionId: run.sessionId,
          agentId: run.sessionAgentId,
          displayName: run.displayName ?? "Codex",
          status: run.status,
          projectDir: run.projectDir,
          threadId: run.threadId,
          turnId: run.turnId,
          active: run.status.isActive,
          attached: run.status.isActive,
          pendingApprovals: run.pendingApprovals.count,
          resolvedApprovals: run.resolvedApprovals.count,
          eventCount: run.events.count,
          lastUpdateAt: run.updatedAt,
          model: run.model,
          effort: run.effort,
          latestSummary: run.latestSummary,
          error: run.error
        )
      }
    )
  }

  func stopManagedAgent(agentID: String) async throws -> ManagedAgentSnapshot {
    if configuredCodexRun(id: agentID) != nil {
      return .codex(try await interruptCodexRun(runID: agentID))
    }
    if lock.withLock({ resolvedAcpSnapshotsByAgentID[agentID] }) != nil {
      return try await stopManagedAcpAgent(agentID: agentID)
    }
    return .terminal(try await stopAgentTui(tuiID: agentID))
  }
}
