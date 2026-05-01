import Foundation

extension HarnessMonitorStore {
  static let agentTuiActionRefreshDelay = Duration.milliseconds(250)
  static let agentTuiActionRefreshAttempts = 4

  @discardableResult
  public func setHostBridgeCapability(
    _ capability: String,
    enabled: Bool,
    force: Bool = false
  ) async -> HostBridgeCapabilityMutationResult {
    guard let client else {
      presentFailureFeedback("Daemon unavailable.")
      return .failed
    }

    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    return await mutateHostBridgeCapability(
      using: client,
      capability: capability,
      enabled: enabled,
      force: force
    )
  }

  @discardableResult
  public func refreshSelectedCodexRuns() async -> Bool {
    guard let client, let sessionID = selectedSessionID else { return false }
    return await refreshCodexRuns(using: client, sessionID: sessionID)
  }

  @discardableResult
  public func refreshSelectedCodexRun() async -> Bool {
    guard let client, let runID = selectedCodexRun?.runId else { return false }
    return await refreshCodexRun(using: client, runID: runID)
  }

  @discardableResult
  public func startCodexRun(
    prompt: String,
    mode: CodexRunMode,
    actor: String = "harness-app",
    resumeThreadId: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false,
    sessionID: String? = nil
  ) async -> Bool {
    await startCodexRunSnapshot(
      prompt: prompt,
      mode: mode,
      actor: actor,
      resumeThreadId: resumeThreadId,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel,
      sessionID: sessionID
    ) != nil
  }

  @discardableResult
  public func startCodexRunSnapshot(
    prompt: String,
    mode: CodexRunMode,
    actor: String = "harness-app",
    resumeThreadId: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false,
    sessionID: String? = nil
  ) async -> CodexRunSnapshot? {
    let actionName = "Start Codex thread"
    guard
      let action = prepareSessionAction(
        named: actionName,
        sessionID: sessionID ?? selectedSessionID
      )
    else {
      return nil
    }
    let resolvedActor = codexStartActionActor(for: actor)

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      presentFailureFeedback("Codex prompt cannot be empty.")
      return nil
    }

    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }

    let request = CodexRunRequest(
      actor: resolvedActor,
      prompt: trimmedPrompt,
      mode: mode,
      resumeThreadId: resumeThreadId,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel
    )

    do {
      let measuredRun = try await measureCodexRunStart(
        using: action.client,
        sessionID: action.sessionID,
        request: request
      )
      applyCodexRunStartSuccess(measuredRun.value)
      return measuredRun.value
    } catch let apiError as HarnessMonitorAPIError {
      let firstFailureRecordedAt = Date.now
      switch await recoverCodexStartAfterTransientBridgeFailure(
        using: action.client,
        sessionID: action.sessionID,
        request: request,
        error: apiError,
        firstFailureRecordedAt: firstFailureRecordedAt
      ) {
      case .succeeded(let run):
        return run
      case .failed:
        return nil
      case .notAttempted:
        break
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(
          for: "codex",
          statusCode: code,
          recordedAt: firstFailureRecordedAt
        )
      }
      presentFailureFeedback(apiError.localizedDescription)
      return nil
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func steerCodexRun(runID: String, prompt: String) async -> Bool {
    let actionName = "Codex context sent"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      presentFailureFeedback("Codex context cannot be empty.")
      return false
    }

    return await mutateCodexRun(actionName: actionName) {
      try await action.client.steerCodexRun(
        runID: runID,
        request: CodexSteerRequest(prompt: trimmedPrompt)
      )
    }
  }

  @discardableResult
  public func interruptCodexRun(runID: String) async -> Bool {
    let actionName = "Codex run interrupted"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    return await interruptCodexRun(sessionID: action.sessionID, runID: runID)
  }

  @discardableResult
  public func interruptCodexRun(sessionID: String, runID: String) async -> Bool {
    let actionName = "Codex run interrupted"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    return await mutateCodexRun(
      actionName: actionName,
      actionID: Self.codexInterruptActionID(for: runID)
    ) {
      try await action.client.interruptCodexRun(runID: runID)
    }
  }

  public func requestInterruptCodexRunConfirmation(_ run: CodexRunSnapshot) {
    let actionName = "Interrupt Codex run"
    guard prepareSessionAction(named: actionName, sessionID: run.sessionId) != nil else { return }
    let runTitle = Self.clippedCodexRunTitle(for: run)
    pendingConfirmation = .interruptCodexRun(
      sessionID: run.sessionId,
      runID: run.runId,
      runTitle: runTitle.isEmpty ? run.runId : runTitle
    )
  }

  public func isInterruptCodexRunInFlight(_ runID: String) -> Bool {
    inFlightActionID == Self.codexInterruptActionID(for: runID)
  }

  @discardableResult
  public func resolveCodexApproval(
    runID: String,
    approvalID: String,
    decision: CodexApprovalDecision
  ) async -> Bool {
    let actionName = "Codex approval resolved"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    return await mutateCodexRun(actionName: actionName) {
      try await action.client.resolveCodexApproval(
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
    if let sessionID = selectedSessionID {
      codexRunsBySessionID[sessionID] = []
    }
    assignCodexRuns([], selected: nil)
  }

  public func selectCodexRun(runID: String?) {
    guard let runID else {
      assignSelectedCodexRun(preferredCodexRun(from: selectedCodexRuns))
      return
    }
    assignSelectedCodexRun(
      selectedCodexRuns.first(where: { $0.runId == runID })
        ?? preferredCodexRun(from: selectedCodexRuns)
    )
  }

  func applyCodexRun(_ run: CodexRunSnapshot, selectingRun: Bool = false) {
    codexRunsBySessionID[run.sessionId] = upsertingCodexRun(
      run,
      into: codexRunsBySessionID[run.sessionId] ?? []
    )
    guard run.sessionId == selectedSessionID else {
      return
    }

    let runs = upsertingCodexRun(run, into: selectedCodexRuns)
    let selected =
      if selectingRun || selectedCodexRun?.runId == run.runId || selectedCodexRun == nil {
        run
      } else {
        selectedCodexRun
      }
    assignCodexRuns(runs, selected: selected)
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
      codexRunsBySessionID[sessionID] = measuredRuns.value.runs
      guard selectedSessionID == sessionID else {
        return true
      }
      assignCodexRuns(
        measuredRuns.value.runs,
        selected: preferredCodexRun(from: measuredRuns.value.runs)
      )
      return true
    } catch {
      guard selectedSessionID == sessionID else {
        return false
      }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func recoverSelectedCodexRunsAfterReconnect(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async {
    do {
      let measuredRuns = try await Self.measureOperation {
        try await client.codexRuns(sessionID: sessionID)
      }
      recordRequestSuccess()
      codexRunsBySessionID[sessionID] = measuredRuns.value.runs
      guard selectedSessionID == sessionID else {
        return
      }
      assignCodexRuns(
        measuredRuns.value.runs,
        selected: preferredCodexRun(from: measuredRuns.value.runs)
      )
    } catch {
      guard selectedSessionID == sessionID else {
        return
      }
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect codex refresh failed: \(err, privacy: .public)"
      )
    }
  }

  func refreshCodexRun(
    using client: any HarnessMonitorClientProtocol,
    runID: String
  ) async -> Bool {
    do {
      let measuredRun = try await Self.measureOperation {
        try await client.codexRun(runID: runID)
      }
      recordRequestSuccess()
      applyCodexRun(measuredRun.value)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func mutateCodexRun(
    actionName: String,
    actionID: String? = nil,
    mutation: @escaping @Sendable () async throws -> CodexRunSnapshot
  ) async -> Bool {
    isSessionActionInFlight = true
    if let actionID {
      inFlightActionID = actionID
    }
    defer {
      isSessionActionInFlight = false
      if let actionID, inFlightActionID == actionID {
        inFlightActionID = nil
      }
    }

    do {
      let measuredRun = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      clearHostBridgeIssue(for: "codex")
      applyCodexRun(measuredRun.value)
      presentSuccessFeedback(actionName)
      return true
    } catch let apiError as HarnessMonitorAPIError {
      if case .server(let code, _) = apiError {
        markHostBridgeIssue(for: "codex", statusCode: code)
      }
      presentFailureFeedback(apiError.localizedDescription)
      return false
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private static func codexInterruptActionID(for runID: String) -> String {
    "codex/interrupt/\(runID)"
  }

  private static func clippedCodexRunTitle(for run: CodexRunSnapshot) -> String {
    let trimmedPrompt = run.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      return run.runId
    }
    let firstLine =
      trimmedPrompt
      .components(separatedBy: .newlines)
      .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      ?? trimmedPrompt
    let clipped = String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    if firstLine.count > clipped.count {
      return "\(clipped)..."
    }
    return clipped
  }

}
