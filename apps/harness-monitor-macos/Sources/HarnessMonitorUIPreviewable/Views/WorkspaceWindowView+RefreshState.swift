import HarnessMonitorKit

extension WorkspaceWindowView {
  struct WorkspaceRefreshState: Equatable {
    let agentTuis: [AgentTuiRefreshSignature]
    let selectedAgentTuiID: String?
    let codexRuns: [CodexRunRefreshSignature]
    let selectedCodexRunID: String?
    let session: SessionRefreshSignature?
    let agentTuiUnavailable: Bool
    let acpUnavailable: Bool
    let codexUnavailable: Bool
  }

  struct AgentTuiRefreshSignature: Equatable {
    let tuiID: String
    let sessionID: String
    let agentID: String
    let runtime: String
    let status: AgentTuiStatus
    let size: AgentTuiSize
    let exitCode: UInt32?
    let signal: String?
    let error: String?
    let createdAt: String

    init(_ snapshot: AgentTuiSnapshot) {
      tuiID = snapshot.tuiId
      sessionID = snapshot.sessionId
      agentID = snapshot.agentId
      runtime = snapshot.runtime
      status = snapshot.status
      size = snapshot.size
      exitCode = snapshot.exitCode
      signal = snapshot.signal
      error = snapshot.error
      createdAt = snapshot.createdAt
    }
  }

  struct CodexRunRefreshSignature: Equatable {
    let runID: String
    let sessionID: String
    let projectDir: String
    let mode: CodexRunMode
    let status: CodexRunStatus
    let prompt: String
    let createdAt: String

    init(_ snapshot: CodexRunSnapshot) {
      runID = snapshot.runId
      sessionID = snapshot.sessionId
      projectDir = snapshot.projectDir
      mode = snapshot.mode
      status = snapshot.status
      prompt = snapshot.prompt
      createdAt = snapshot.createdAt
    }
  }

  struct SessionRefreshSignature: Equatable {
    let sessionID: String
    let title: String
    let agents: [AgentRefreshSignature]
    let taskIDs: [String]

    init(_ detail: SessionDetail) {
      sessionID = detail.session.sessionId
      title = detail.session.title
      agents = detail.agents.map(AgentRefreshSignature.init)
      taskIDs = detail.tasks.map(\.taskId)
    }
  }

  struct AgentRefreshSignature: Equatable {
    let agentID: String
    let name: String
    let runtime: String
    let role: SessionRole
    let status: AgentStatus
    let currentTaskID: String?
    let isAutoSpawned: Bool

    init(_ agent: AgentRegistration) {
      agentID = agent.agentId
      name = agent.name
      runtime = agent.runtime
      role = agent.role
      status = agent.status
      currentTaskID = agent.currentTaskId
      isAutoSpawned = agent.isAutoSpawned
    }
  }

  var workspaceRefreshState: WorkspaceRefreshState {
    WorkspaceRefreshState(
      agentTuis: store.selectedAgentTuis.map(AgentTuiRefreshSignature.init),
      selectedAgentTuiID: store.selectedAgentTui?.tuiId,
      codexRuns: store.selectedCodexRuns.map(CodexRunRefreshSignature.init),
      selectedCodexRunID: store.selectedCodexRun?.runId,
      session: store.selectedSession.map(SessionRefreshSignature.init),
      agentTuiUnavailable: store.agentTuiUnavailable,
      acpUnavailable: store.acpUnavailable,
      codexUnavailable: store.codexUnavailable
    )
  }
}
