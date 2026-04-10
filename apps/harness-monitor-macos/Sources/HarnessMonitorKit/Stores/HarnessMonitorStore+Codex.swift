import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func refreshSelectedCodexRuns() async -> Bool {
    guard let client, let sessionID = selectedSessionID else { return false }
    return await refreshCodexRuns(using: client, sessionID: sessionID)
  }

  @discardableResult
  public func startCodexRun(
    prompt: String,
    mode: CodexRunMode,
    actor: String = "harness-app",
    resumeThreadId: String? = nil
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client, let sessionID = selectedSessionID else { return false }
    guard let actor = actionActor(for: actor) else { return false }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      lastError = "Codex prompt cannot be empty."
      return false
    }

    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }
    lastError = nil

    do {
      let measuredRun = try await Self.measureOperation {
        try await client.startCodexRun(
          sessionID: sessionID,
          request: CodexRunRequest(
            actor: actor,
            prompt: trimmedPrompt,
            mode: mode,
            resumeThreadId: resumeThreadId
          )
        )
      }
      recordRequestSuccess()
      applyCodexRun(measuredRun.value)
      showLastAction("Codex run started")
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  @discardableResult
  public func steerCodexRun(runID: String, prompt: String) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      lastError = "Codex context cannot be empty."
      return false
    }

    return await mutateCodexRun(actionName: "Codex context sent") {
      try await client.steerCodexRun(
        runID: runID,
        request: CodexSteerRequest(prompt: trimmedPrompt)
      )
    }
  }

  @discardableResult
  public func interruptCodexRun(runID: String) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }
    return await mutateCodexRun(actionName: "Codex run interrupted") {
      try await client.interruptCodexRun(runID: runID)
    }
  }

  @discardableResult
  public func resolveCodexApproval(
    runID: String,
    approvalID: String,
    decision: CodexApprovalDecision
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }
    return await mutateCodexRun(actionName: "Codex approval resolved") {
      try await client.resolveCodexApproval(
        runID: runID,
        approvalID: approvalID,
        request: CodexApprovalDecisionRequest(decision: decision)
      )
    }
  }

  func resetSelectedCodexRuns() {
    guard !selectedCodexRuns.isEmpty || selectedCodexRun != nil else {
      return
    }
    selectedCodexRuns = []
    selectedCodexRun = nil
  }

  func applyCodexRun(_ run: CodexRunSnapshot) {
    guard run.sessionId == selectedSessionID else {
      return
    }

    let runs = upsertingCodexRun(run, into: selectedCodexRuns)
    selectedCodexRuns = runs
    if selectedCodexRun?.runId == run.runId || selectedCodexRun == nil {
      selectedCodexRun = run
    }
  }

  func applyCodexApprovalRequested(_ payload: CodexApprovalRequestedPayload) {
    applyCodexRun(payload.run)
  }

  func refreshCodexRuns(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async -> Bool {
    do {
      let measuredRuns = try await Self.measureOperation {
        try await client.codexRuns(sessionID: sessionID)
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return true
      }
      selectedCodexRuns = measuredRuns.value.runs
      selectedCodexRun = preferredCodexRun(from: measuredRuns.value.runs)
      return true
    } catch {
      guard selectedSessionID == sessionID else {
        return false
      }
      lastError = error.localizedDescription
      return false
    }
  }

  private func mutateCodexRun(
    actionName: String,
    mutation: @escaping @Sendable () async throws -> CodexRunSnapshot
  ) async -> Bool {
    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }
    lastError = nil

    do {
      let measuredRun = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      applyCodexRun(measuredRun.value)
      showLastAction(actionName)
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  private func preferredCodexRun(from runs: [CodexRunSnapshot]) -> CodexRunSnapshot? {
    if let selectedRunID = selectedCodexRun?.runId {
      if let selectedRun = runs.first(where: { $0.runId == selectedRunID }) {
        return selectedRun
      }
    }
    return runs.first { $0.status.isActive } ?? runs.first
  }

  private func upsertingCodexRun(
    _ run: CodexRunSnapshot,
    into runs: [CodexRunSnapshot]
  ) -> [CodexRunSnapshot] {
    var updatedRuns = runs.filter { $0.runId != run.runId }
    updatedRuns.insert(run, at: 0)
    return updatedRuns
  }
}
