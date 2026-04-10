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
      codexUnavailable = false
      applyCodexRun(measuredRun.value)
      showLastAction("Codex run started")
      return true
    } catch let apiError as HarnessMonitorAPIError {
      if case .server(let code, _) = apiError, code == 503 {
        codexUnavailable = true
      }
      lastError = apiError.localizedDescription
      return false
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

extension HarnessMonitorStore {
  @discardableResult
  public func refreshSelectedAgentTuis() async -> Bool {
    guard let client, let sessionID = selectedSessionID else { return false }
    return await refreshAgentTuis(using: client, sessionID: sessionID)
  }

  @discardableResult
  public func refreshSelectedAgentTui() async -> Bool {
    guard let client, let tuiID = selectedAgentTui?.tuiId else { return false }
    return await refreshAgentTui(using: client, tuiID: tuiID)
  }

  @discardableResult
  public func startAgentTui(
    runtime: AgentTuiRuntime,
    name: String?,
    prompt: String?,
    rows: Int,
    cols: Int
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client, let sessionID = selectedSessionID else { return false }
    guard rows > 0, cols > 0 else {
      lastError = "Terminal size must be greater than zero."
      return false
    }

    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)

    return await mutateAgentTui(actionName: "Agent TUI started") {
      try await client.startAgentTui(
        sessionID: sessionID,
        request: AgentTuiStartRequest(
          runtime: runtime.rawValue,
          name: trimmedName?.isEmpty == false ? trimmedName : nil,
          prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
          rows: rows,
          cols: cols
        )
      )
    }
  }

  @discardableResult
  public func sendAgentTuiInput(
    tuiID: String,
    input: AgentTuiInput
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }

    return await mutateAgentTui {
      try await client.sendAgentTuiInput(
        tuiID: tuiID,
        request: AgentTuiInputRequest(input: input)
      )
    }
  }

  @discardableResult
  public func resizeAgentTui(
    tuiID: String,
    rows: Int,
    cols: Int
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }
    guard rows > 0, cols > 0 else {
      lastError = "Terminal size must be greater than zero."
      return false
    }

    return await mutateAgentTui(actionName: "Agent TUI resized") {
      try await client.resizeAgentTui(
        tuiID: tuiID,
        request: AgentTuiResizeRequest(rows: rows, cols: cols)
      )
    }
  }

  @discardableResult
  public func stopAgentTui(tuiID: String) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }

    return await mutateAgentTui(actionName: "Agent TUI stopped") {
      try await client.stopAgentTui(tuiID: tuiID)
    }
  }

  public func selectAgentTui(tuiID: String?) {
    guard let tuiID else {
      selectedAgentTui = preferredAgentTui(from: selectedAgentTuis)
      return
    }
    selectedAgentTui = selectedAgentTuis.first(where: { $0.tuiId == tuiID })
      ?? preferredAgentTui(from: selectedAgentTuis)
  }

  func resetSelectedAgentTuis() {
    agentTuiUnavailable = false
    guard !selectedAgentTuis.isEmpty || selectedAgentTui != nil else {
      return
    }
    selectedAgentTuis = []
    selectedAgentTui = nil
  }

  func applyAgentTui(_ tui: AgentTuiSnapshot) {
    guard tui.sessionId == selectedSessionID else {
      return
    }

    agentTuiUnavailable = false
    let tuis = upsertingAgentTui(tui, into: selectedAgentTuis)
    selectedAgentTuis = tuis
    if selectedAgentTui?.tuiId == tui.tuiId || selectedAgentTui == nil {
      selectedAgentTui = tui
    }
  }

  func refreshAgentTuis(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async -> Bool {
    do {
      let measuredTuis = try await Self.measureOperation {
        try await client.agentTuis(sessionID: sessionID)
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return true
      }
      agentTuiUnavailable = false
      selectedAgentTuis = measuredTuis.value.tuis
      selectedAgentTui = preferredAgentTui(from: measuredTuis.value.tuis)
      return true
    } catch {
      return applyAgentTuiError(error, selectedSessionID: sessionID)
    }
  }

  func refreshAgentTui(
    using client: any HarnessMonitorClientProtocol,
    tuiID: String
  ) async -> Bool {
    do {
      let measuredTui = try await Self.measureOperation {
        try await client.agentTui(tuiID: tuiID)
      }
      recordRequestSuccess()
      applyAgentTui(measuredTui.value)
      return true
    } catch {
      return applyAgentTuiError(error, selectedSessionID: selectedSessionID)
    }
  }

  private func mutateAgentTui(
    actionName: String? = nil,
    mutation: @escaping @Sendable () async throws -> AgentTuiSnapshot
  ) async -> Bool {
    lastError = nil

    do {
      let measuredTui = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      agentTuiUnavailable = false
      applyAgentTui(measuredTui.value)
      if let actionName {
        showLastAction(actionName)
      }
      return true
    } catch {
      return applyAgentTuiError(error, selectedSessionID: selectedSessionID)
    }
  }

  private func applyAgentTuiError(
    _ error: any Error,
    selectedSessionID: String?
  ) -> Bool {
    guard selectedSessionID == self.selectedSessionID else {
      return false
    }
    if let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 501
    {
      agentTuiUnavailable = true
    }
    lastError = error.localizedDescription
    return false
  }

  private func preferredAgentTui(from tuis: [AgentTuiSnapshot]) -> AgentTuiSnapshot? {
    if let selectedTuiID = selectedAgentTui?.tuiId,
      let selectedTui = tuis.first(where: { $0.tuiId == selectedTuiID })
    {
      return selectedTui
    }
    return tuis.first(where: { $0.status.isActive }) ?? tuis.first
  }

  private func upsertingAgentTui(
    _ tui: AgentTuiSnapshot,
    into tuis: [AgentTuiSnapshot]
  ) -> [AgentTuiSnapshot] {
    var updatedTuis = tuis.filter { $0.tuiId != tui.tuiId }
    updatedTuis.insert(tui, at: 0)
    return updatedTuis
  }
}
