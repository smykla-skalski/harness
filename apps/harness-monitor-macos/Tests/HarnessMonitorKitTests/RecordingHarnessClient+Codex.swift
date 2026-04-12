import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .reconfigureHostBridge(
        enable: request.enable,
        disable: request.disable,
        force: request.force
      )
    )
    if let error = configuredHostBridgeReconfigureError() {
      throw error
    }
    return configuredHostBridgeStatusReport()
  }

  func codexRuns(sessionID: String) async throws -> CodexRunListResponse {
    CodexRunListResponse(runs: configuredCodexRuns(for: sessionID))
  }

  func codexRun(runID: String) async throws -> CodexRunSnapshot {
    if let run = configuredCodexRun(id: runID) {
      return run
    }
    throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
  }

  func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .startCodexRun(
        sessionID: sessionID,
        prompt: request.prompt,
        mode: request.mode,
        actor: request.actor,
        resumeThreadID: request.resumeThreadId
      )
    )
    if let error = dequeueConfiguredCodexStartError() {
      throw error
    }
    let run = codexRunFixture(
      runID: "codex-run-\(configuredCodexRuns(for: sessionID).count + 1)",
      sessionID: sessionID,
      mode: request.mode,
      status: .queued,
      prompt: request.prompt
    )
    recordCodexRun(run)
    return run
  }

  func steerCodexRun(
    runID: String,
    request: CodexSteerRequest
  ) async throws -> CodexRunSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.steerCodexRun(runID: runID, prompt: request.prompt))
    guard let run = configuredCodexRun(id: runID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    let updated = codexRunFixture(
      runID: run.runId,
      sessionID: run.sessionId,
      mode: run.mode,
      status: run.status,
      prompt: run.prompt,
      latestSummary: "Accepted new context."
    )
    recordCodexRun(updated)
    return updated
  }

  func interruptCodexRun(runID: String) async throws -> CodexRunSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.interruptCodexRun(runID: runID))
    guard let run = configuredCodexRun(id: runID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    let updated = codexRunFixture(
      runID: run.runId,
      sessionID: run.sessionId,
      mode: run.mode,
      status: .cancelled,
      prompt: run.prompt
    )
    recordCodexRun(updated)
    return updated
  }

  func resolveCodexApproval(
    runID: String,
    approvalID: String,
    request: CodexApprovalDecisionRequest
  ) async throws -> CodexRunSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(
      .resolveCodexApproval(
        runID: runID,
        approvalID: approvalID,
        decision: request.decision
      )
    )
    guard let run = configuredCodexRun(id: runID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    let updated = codexRunFixture(
      runID: run.runId,
      sessionID: run.sessionId,
      mode: run.mode,
      status: .running,
      prompt: run.prompt
    )
    recordCodexRun(updated)
    return updated
  }

  func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    AgentTuiListResponse(tuis: configuredAgentTuis(for: sessionID))
  }

  func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    if let tui = dequeueConfiguredAgentTuiReadSnapshot(id: tuiID) {
      return tui
    }
    if let tui = configuredAgentTui(id: tuiID) {
      return tui
    }
    throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
  }

  func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    if let error = configuredAgentTuiStartError() {
      throw error
    }
    calls.append(
      .startAgentTui(
        sessionID: sessionID,
        runtime: request.runtime,
        name: request.name,
        prompt: request.prompt,
        projectDir: request.projectDir,
        argv: request.argv,
        rows: request.rows,
        cols: request.cols
      )
    )
    let tui = agentTuiFixture(
      tuiID: "agent-tui-\(configuredAgentTuis(for: sessionID).count + 1)",
      sessionID: sessionID,
      runtime: request.runtime,
      status: .running,
      argv: request.argv.isEmpty ? [request.runtime] : request.argv,
      projectDir: request.projectDir ?? PreviewFixtures.summary.projectDir
        ?? PreviewFixtures.summary.contextRoot,
      rows: request.rows,
      cols: request.cols
    )
    recordAgentTui(tui)
    return tui
  }

  func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.sendAgentTuiInput(tuiID: tuiID, input: request.input))
    guard let tui = configuredAgentTui(id: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    if let updated = dequeueConfiguredAgentTuiInputResponse(id: tuiID) {
      return updated
    }
    let updatedScreenText: String =
      switch request.input {
      case .text(let text), .paste(let text):
        [tui.screen.text, text].filter { !$0.isEmpty }.joined(separator: "\n")
      case .key(let key):
        [tui.screen.text, "[\(key.title)]"].filter { !$0.isEmpty }.joined(separator: "\n")
      case .control(let key):
        [tui.screen.text, "[Ctrl-\(String(key).uppercased())]"].filter { !$0.isEmpty }.joined(
          separator: "\n")
      case .rawBytesBase64:
        [tui.screen.text, "[raw bytes]"].filter { !$0.isEmpty }.joined(separator: "\n")
      }
    let updated = agentTuiFixture(
      tuiID: tui.tuiId,
      sessionID: tui.sessionId,
      runtime: tui.runtime,
      status: tui.status,
      rows: tui.size.rows,
      cols: tui.size.cols,
      screenText: updatedScreenText
    )
    recordAgentTui(updated)
    return updated
  }

  func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.resizeAgentTui(tuiID: tuiID, rows: request.rows, cols: request.cols))
    guard let tui = configuredAgentTui(id: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    let updated = agentTuiFixture(
      tuiID: tui.tuiId,
      sessionID: tui.sessionId,
      runtime: tui.runtime,
      status: tui.status,
      rows: request.rows,
      cols: request.cols,
      screenText: tui.screen.text
    )
    recordAgentTui(updated)
    return updated
  }

  func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await sleepIfNeeded(configuredMutationDelay())
    calls.append(.stopAgentTui(tuiID: tuiID))
    guard let tui = configuredAgentTui(id: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    let updated = agentTuiFixture(
      tuiID: tui.tuiId,
      sessionID: tui.sessionId,
      runtime: tui.runtime,
      status: .stopped,
      rows: tui.size.rows,
      cols: tui.size.cols,
      screenText: tui.screen.text
    )
    recordAgentTui(updated)
    return updated
  }

  func codexRunFixture(
    runID: String = "codex-run-1",
    sessionID: String = PreviewFixtures.summary.sessionId,
    mode: CodexRunMode = .report,
    status: CodexRunStatus = .running,
    prompt: String = "Summarize this session",
    latestSummary: String? = "Reading the session context.",
    finalMessage: String? = nil,
    error: String? = nil,
    pendingApprovals: [CodexApprovalRequest] = []
  ) -> CodexRunSnapshot {
    CodexRunSnapshot(
      runId: runID,
      sessionId: sessionID,
      projectDir: PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      threadId: "thread-\(runID)",
      turnId: "turn-\(runID)",
      mode: mode,
      status: status,
      prompt: prompt,
      latestSummary: latestSummary,
      finalMessage: finalMessage,
      error: error,
      pendingApprovals: pendingApprovals,
      createdAt: "2026-04-09T10:00:00Z",
      updatedAt: "2026-04-09T10:01:00Z"
    )
  }

  func codexApprovalFixture(
    approvalID: String = "approval-1"
  ) -> CodexApprovalRequest {
    CodexApprovalRequest(
      approvalId: approvalID,
      requestId: "json-rpc-approval-1",
      kind: "command",
      title: "Run cargo test",
      detail: "cargo test --lib",
      threadId: "thread-codex-run-1",
      turnId: "turn-codex-run-1",
      itemId: "item-codex-run-1",
      cwd: PreviewFixtures.summary.contextRoot,
      command: "cargo test --lib",
      filePath: nil
    )
  }

  func agentTuiFixture(
    tuiID: String = "agent-tui-1",
    sessionID: String = PreviewFixtures.summary.sessionId,
    runtime: String = AgentTuiRuntime.copilot.rawValue,
    status: AgentTuiStatus = .running,
    argv: [String]? = nil,
    projectDir: String? = nil,
    rows: Int = 32,
    cols: Int = 120,
    screenText: String = "copilot> ready",
    error: String? = nil
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: tuiID,
      sessionId: sessionID,
      agentId: "agent-\(tuiID)",
      runtime: runtime,
      status: status,
      argv: argv ?? [runtime],
      projectDir: projectDir ?? PreviewFixtures.summary.projectDir ?? PreviewFixtures.summary.contextRoot,
      size: AgentTuiSize(rows: rows, cols: cols),
      screen: AgentTuiScreenSnapshot(
        rows: rows,
        cols: cols,
        cursorRow: 1,
        cursorCol: min(12, max(cols, 1)),
        text: screenText
      ),
      transcriptPath: PreviewFixtures.summary.contextRoot + "/transcripts/\(tuiID).log",
      exitCode: status == .stopped ? 0 : nil,
      signal: nil,
      error: error,
      createdAt: "2026-04-10T09:00:00Z",
      updatedAt: "2026-04-10T09:01:00Z"
    )
  }
}
