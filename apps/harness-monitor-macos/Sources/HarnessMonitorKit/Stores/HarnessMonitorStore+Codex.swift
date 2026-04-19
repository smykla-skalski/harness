import Foundation

extension HarnessMonitorStore {
  static let agentTuiActionRefreshDelay = Duration.milliseconds(250)
  static let agentTuiActionRefreshAttempts = 4

  private enum CodexStartRecoveryOutcome {
    case notAttempted
    case succeeded(CodexRunSnapshot)
    case failed
  }

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
    allowCustomModel: Bool = false
  ) async -> Bool {
    await startCodexRunSnapshot(
      prompt: prompt,
      mode: mode,
      actor: actor,
      resumeThreadId: resumeThreadId,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel
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
    allowCustomModel: Bool = false
  ) async -> CodexRunSnapshot? {
    guard guardSessionActionsAvailable() else { return nil }
    guard let client, let sessionID = selectedSessionID else { return nil }
    guard let actor = actionActor(for: actor) else { return nil }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      presentFailureFeedback("Codex prompt cannot be empty.")
      return nil
    }

    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }

    let request = CodexRunRequest(
      actor: actor,
      prompt: trimmedPrompt,
      mode: mode,
      resumeThreadId: resumeThreadId,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel
    )

    do {
      let measuredRun = try await measureCodexRunStart(
        using: client,
        sessionID: sessionID,
        request: request
      )
      applyCodexRunStartSuccess(measuredRun.value)
      return measuredRun.value
    } catch let apiError as HarnessMonitorAPIError {
      switch await recoverCodexStartAfterTransientBridgeFailure(
        using: client,
        sessionID: sessionID,
        request: request,
        error: apiError
      ) {
      case .succeeded(let run):
        return run
      case .failed:
        return nil
      case .notAttempted:
        break
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(for: "codex", statusCode: code)
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
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }

    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      presentFailureFeedback("Codex context cannot be empty.")
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

  public func selectCodexRun(runID: String?) {
    guard let runID else {
      selectedCodexRun = preferredCodexRun(from: selectedCodexRuns)
      return
    }
    selectedCodexRun =
      selectedCodexRuns.first(where: { $0.runId == runID })
      ?? preferredCodexRun(from: selectedCodexRuns)
  }

  func applyCodexRun(_ run: CodexRunSnapshot, selectingRun: Bool = false) {
    guard run.sessionId == selectedSessionID else {
      return
    }

    let runs = upsertingCodexRun(run, into: selectedCodexRuns)
    selectedCodexRuns = runs
    if selectingRun || selectedCodexRun?.runId == run.runId || selectedCodexRun == nil {
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
      guard selectedSessionID == sessionID else {
        return
      }
      selectedCodexRuns = measuredRuns.value.runs
      selectedCodexRun = preferredCodexRun(from: measuredRuns.value.runs)
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
    mutation: @escaping @Sendable () async throws -> CodexRunSnapshot
  ) async -> Bool {
    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }

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

  private func measureCodexRunStart(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> MeasuredOperation<CodexRunSnapshot> {
    try await Self.measureOperation {
      try await client.startCodexRun(
        sessionID: sessionID,
        request: request
      )
    }
  }

  private func applyCodexRunStartSuccess(_ run: CodexRunSnapshot) {
    recordRequestSuccess()
    clearHostBridgeIssue(for: "codex")
    applyCodexRun(run, selectingRun: true)
    presentSuccessFeedback("Codex run started")
  }

  private func recoverCodexStartAfterTransientBridgeFailure(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    request: CodexRunRequest,
    error: HarnessMonitorAPIError
  ) async -> CodexStartRecoveryOutcome {
    guard case .server(let code, _) = error, code == 503 else {
      return .notAttempted
    }
    guard daemonStatus?.manifest?.sandboxed == true else {
      return .notAttempted
    }

    await refreshDaemonStatus()
    reconcileHostBridgeIssueFromManifest(for: "codex")

    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    guard hostBridge.running, hostBridge.capabilities["codex"]?.healthy == true else {
      markHostBridgeIssue(for: "codex", statusCode: code)
      return .notAttempted
    }

    do {
      let measuredRun = try await measureCodexRunStart(
        using: client,
        sessionID: sessionID,
        request: request
      )
      applyCodexRunStartSuccess(measuredRun.value)
      return .succeeded(measuredRun.value)
    } catch let retryError as HarnessMonitorAPIError {
      if case .server(let retryCode, _) = retryError, retryCode == 501 || retryCode == 503 {
        markHostBridgeIssue(for: "codex", statusCode: retryCode)
      }
      presentFailureFeedback(retryError.localizedDescription)
      return .failed
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return .failed
    }
  }

  private func reconcileHostBridgeIssueFromManifest(for capability: String) {
    guard !forcedHostBridgeCapabilities.contains(capability) else {
      return
    }
    let hostBridge = daemonStatus?.manifest?.hostBridge ?? HostBridgeManifest()
    guard daemonStatus?.manifest?.sandboxed == true else {
      clearHostBridgeIssue(for: capability)
      return
    }
    guard hostBridge.running else {
      hostBridgeCapabilityIssues[capability] = .unavailable
      return
    }
    guard let capabilityState = hostBridge.capabilities[capability] else {
      hostBridgeCapabilityIssues[capability] = .excluded
      return
    }
    if capabilityState.healthy {
      clearHostBridgeIssue(for: capability)
    } else {
      hostBridgeCapabilityIssues[capability] = .unavailable
    }
  }
}
