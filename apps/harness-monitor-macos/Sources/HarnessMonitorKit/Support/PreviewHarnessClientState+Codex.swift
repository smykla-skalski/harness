import Foundation

extension PreviewHarnessClientState {
  func codexRuns(sessionID: String) -> [CodexRunSnapshot] {
    codexRunsBySessionID[sessionID] ?? []
  }

  func codexRun(runID: String) -> CodexRunSnapshot? {
    codexRunsBySessionID.values
      .flatMap(\.self)
      .first { run in
        run.runId == runID
      }
  }

  func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) -> CodexRunSnapshot {
    nextCodexRunSequence += 1
    let run = CodexRunSnapshot(
      runId: "preview-codex-run-\(nextCodexRunSequence)",
      sessionId: sessionID,
      projectDir: fallbackDetail?.session.projectDir ?? "/Users/example/Projects/harness",
      threadId: request.resumeThreadId,
      turnId: nil,
      mode: request.mode,
      status: .queued,
      prompt: request.prompt,
      latestSummary: request.actor.map { "Queued by \($0)" } ?? "Queued by preview",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    var runs = codexRunsBySessionID[sessionID] ?? []
    runs.removeAll { $0.runId == run.runId }
    runs.insert(run, at: 0)
    codexRunsBySessionID[sessionID] = runs
    return run
  }

  func resolveCodexApproval(
    runID: String,
    approvalID: String,
    decision: CodexApprovalDecision
  ) -> CodexRunSnapshot? {
    _ = decision
    return mutateCodexRun(runID: runID) { run in
      let approvals = run.pendingApprovals.filter { $0.approvalId != approvalID }
      return CodexRunSnapshot(
        runId: run.runId,
        sessionId: run.sessionId,
        projectDir: run.projectDir,
        threadId: run.threadId,
        turnId: run.turnId,
        mode: run.mode,
        status: approvals.isEmpty ? .running : run.status,
        prompt: run.prompt,
        latestSummary: "Approval \(approvalID) resolved in preview",
        finalMessage: run.finalMessage,
        error: run.error,
        pendingApprovals: approvals,
        createdAt: run.createdAt,
        updatedAt: Self.mutationTimestamp
      )
    }
  }

  private func mutateCodexRun(
    runID: String,
    transform: (CodexRunSnapshot) -> CodexRunSnapshot
  ) -> CodexRunSnapshot? {
    for (sessionID, runs) in codexRunsBySessionID {
      guard let index = runs.firstIndex(where: { $0.runId == runID }) else {
        continue
      }
      let updatedRun = transform(runs[index])
      var updatedRuns = runs
      updatedRuns[index] = updatedRun
      codexRunsBySessionID[sessionID] = updatedRuns
      return updatedRun
    }
    return nil
  }
}
