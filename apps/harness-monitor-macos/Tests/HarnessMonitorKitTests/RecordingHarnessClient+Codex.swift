import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
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
}
