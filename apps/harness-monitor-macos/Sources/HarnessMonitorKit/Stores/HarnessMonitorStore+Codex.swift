import Foundation

extension HarnessMonitorStore {
  private static let agentTuiActionRefreshDelay = Duration.milliseconds(250)
  private static let agentTuiActionRefreshAttempts = 4

  private enum CodexStartRecoveryOutcome {
    case notAttempted
    case succeeded
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
      presentFailureFeedback("Codex prompt cannot be empty.")
      return false
    }

    isSessionActionInFlight = true
    defer { isSessionActionInFlight = false }

    let request = CodexRunRequest(
      actor: actor,
      prompt: trimmedPrompt,
      mode: mode,
      resumeThreadId: resumeThreadId
    )

    do {
      let measuredRun = try await measureCodexRunStart(
        using: client,
        sessionID: sessionID,
        request: request
      )
      applyCodexRunStartSuccess(measuredRun.value)
      return true
    } catch let apiError as HarnessMonitorAPIError {
      switch await recoverCodexStartAfterTransientBridgeFailure(
        using: client,
        sessionID: sessionID,
        request: request,
        error: apiError
      ) {
      case .succeeded:
        return true
      case .failed:
        return false
      case .notAttempted:
        break
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(for: "codex", statusCode: code)
      }
      presentFailureFeedback(apiError.localizedDescription)
      return false
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
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
    applyCodexRun(run)
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
      return .succeeded
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

extension HarnessMonitorStore {
  @discardableResult
  public func refreshSelectedAgentTuis() async -> Bool {
    cancelAgentTuiActionRefresh()
    guard let client, let sessionID = selectedSessionID else { return false }
    return await refreshAgentTuis(using: client, sessionID: sessionID)
  }

  @discardableResult
  public func refreshSelectedAgentTui() async -> Bool {
    cancelAgentTuiActionRefresh()
    guard let client, let tuiID = selectedAgentTui?.tuiId else { return false }
    return await refreshAgentTui(using: client, tuiID: tuiID)
  }

  @discardableResult
  public func startAgentTui(
    runtime: AgentTuiRuntime,
    name: String?,
    prompt: String?,
    projectDir: String? = nil,
    argv: [String] = [],
    rows: Int,
    cols: Int
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client, let sessionID = selectedSessionID else { return false }
    guard rows > 0, cols > 0 else {
      presentFailureFeedback("Terminal size must be greater than zero.")
      return false
    }

    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProjectDir = projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedArgv = argv
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return await mutateAgentTui(
      using: client,
      actionName: "Agent TUI started",
      selectUpdatedSnapshot: true
    ) {
      try await client.startAgentTui(
        sessionID: sessionID,
        request: AgentTuiStartRequest(
          runtime: runtime.rawValue,
          name: trimmedName?.isEmpty == false ? trimmedName : nil,
          prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
          projectDir: trimmedProjectDir?.isEmpty == false ? trimmedProjectDir : nil,
          argv: normalizedArgv,
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

    return await mutateAgentTui(using: client) {
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
      presentFailureFeedback("Terminal size must be greater than zero.")
      return false
    }

    return await mutateAgentTui(using: client, actionName: "Agent TUI resized") {
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

    return await mutateAgentTui(using: client, actionName: "Agent TUI stopped") {
      try await client.stopAgentTui(tuiID: tuiID)
    }
  }

  public func selectAgentTui(tuiID: String?) {
    let previousTuiID = selectedAgentTui?.tuiId
    guard let tuiID else {
      selectedAgentTui = preferredAgentTui(from: selectedAgentTuis)
      if selectedAgentTui?.tuiId != previousTuiID {
        cancelAgentTuiActionRefresh()
      }
      return
    }
    selectedAgentTui = selectedAgentTuis.first(where: { $0.tuiId == tuiID })
      ?? preferredAgentTui(from: selectedAgentTuis)
    if selectedAgentTui?.tuiId != previousTuiID {
      cancelAgentTuiActionRefresh()
    }
  }

  func resetSelectedAgentTuis() {
    clearHostBridgeIssue(for: "agent-tui")
    cancelAgentTuiActionRefresh()
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

    clearHostBridgeIssue(for: "agent-tui")
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
      clearHostBridgeIssue(for: "agent-tui")
      cancelAgentTuiActionRefresh()
      let sortedTuis = measuredTuis.value.canonicallySorted(roleByAgent: selectedSessionRoles()).tuis
      selectedAgentTuis = sortedTuis
      selectedAgentTui = preferredAgentTui(from: sortedTuis)
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
    using client: any HarnessMonitorClientProtocol,
    actionName: String? = nil,
    selectUpdatedSnapshot: Bool = false,
    mutation: @escaping @Sendable () async throws -> AgentTuiSnapshot
  ) async -> Bool {
    do {
      let measuredTui = try await Self.measureOperation {
        try await mutation()
      }
      recordRequestSuccess()
      clearHostBridgeIssue(for: "agent-tui")
      applyAgentTui(measuredTui.value)
      if selectUpdatedSnapshot {
        selectAgentTui(tuiID: measuredTui.value.tuiId)
      }
      scheduleAgentTuiActionRefresh(using: client, baseline: measuredTui.value)
      if let actionName {
        presentSuccessFeedback(actionName)
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
      markHostBridgeIssue(for: "agent-tui", statusCode: code)
    }
    presentFailureFeedback(error.localizedDescription)
    return false
  }

  private func scheduleAgentTuiActionRefresh(
    using client: any HarnessMonitorClientProtocol,
    baseline: AgentTuiSnapshot
  ) {
    guard baseline.status.isActive else {
      cancelAgentTuiActionRefresh(for: baseline.tuiId)
      return
    }

    agentTuiActionRefreshSequence &+= 1
    let token = agentTuiActionRefreshSequence
    pendingAgentTuiActionRefresh = (tuiID: baseline.tuiId, token: token)
    agentTuiActionRefreshTask?.cancel()
    agentTuiActionRefreshTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      defer {
        if pendingAgentTuiActionRefresh?.token == token {
          pendingAgentTuiActionRefresh = nil
          agentTuiActionRefreshTask = nil
        }
      }

      for _ in 0 ..< Self.agentTuiActionRefreshAttempts {
        try? await Task.sleep(for: Self.agentTuiActionRefreshDelay)
        guard !Task.isCancelled else {
          return
        }
        guard
          pendingAgentTuiActionRefresh?.token == token,
          pendingAgentTuiActionRefresh?.tuiID == baseline.tuiId,
          selectedAgentTui?.tuiId == baseline.tuiId
        else {
          return
        }
        if selectedAgentTui != baseline {
          return
        }
        let updated = await refreshAgentTuiAfterAction(using: client, baseline: baseline)
        if updated || selectedAgentTui?.status.isActive != true {
          return
        }
      }
    }
  }

  func cancelAgentTuiActionRefresh(for tuiID: String? = nil) {
    guard tuiID == nil || pendingAgentTuiActionRefresh?.tuiID == tuiID else {
      return
    }

    pendingAgentTuiActionRefresh = nil
    agentTuiActionRefreshTask?.cancel()
    agentTuiActionRefreshTask = nil
  }

  private func refreshAgentTuiAfterAction(
    using client: any HarnessMonitorClientProtocol,
    baseline: AgentTuiSnapshot
  ) async -> Bool {
    do {
      let measuredTui = try await Self.measureOperation {
        try await client.agentTui(tuiID: baseline.tuiId)
      }
      recordRequestSuccess()
      guard selectedAgentTui?.tuiId == baseline.tuiId else {
        return true
      }
      clearHostBridgeIssue(for: "agent-tui")
      applyAgentTui(measuredTui.value)
      return measuredTui.value != baseline
    } catch {
      HarnessMonitorLogger.store.warning(
        "agent TUI post-action refresh failed for \(baseline.tuiId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return true
    }
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
    updatedTuis.append(tui)
    return AgentTuiListResponse(tuis: updatedTuis)
      .canonicallySorted(roleByAgent: selectedSessionRoles()).tuis
  }

  private func selectedSessionRoles() -> [String: SessionRole] {
    Dictionary(
      uniqueKeysWithValues:
        (selectedSession?.agents ?? []).map { ($0.agentId, $0.role) }
    )
  }

  private func applyHostBridgeStatus(_ status: BridgeStatusReport) {
    guard let daemonStatus else {
      return
    }
    self.daemonStatus = daemonStatus.updating(hostBridge: status.hostBridgeManifest)
  }

  /// Apply a lightweight in-place manifest update triggered by the
  /// `ManifestWatcher` file-system event. Refreshes `daemonStatus` with the
  /// new `hostBridge` snapshot and clears any transient
  /// `hostBridgeCapabilityIssues` picked up from earlier 501/503 responses,
  /// so stale "unavailable" flags do not shadow a freshly-healthy bridge.
  /// Preserves launch agent, project counts, diagnostics, and every other
  /// daemon status field.
  ///
  /// Also emits a `.info` entry in the connection timeline so operators
  /// can see revision transitions in the visible event log without
  /// grepping the unified log. No `reconnect`, no HTTP round-trip, no
  /// stream teardown - exactly one observable slice assignment on the
  /// MainActor per update.
  ///
  /// No-op when `daemonStatus` is nil (bootstrap has not finished) - the
  /// initial `daemonStatus` assignment will carry the latest manifest
  /// anyway via `refreshDaemonStatus`.
  func applyManifestRevision(_ manifest: DaemonManifest) {
    guard let current = daemonStatus else {
      return
    }
    daemonStatus = current.updating(hostBridge: manifest.hostBridge)
    clearTransientHostBridgeIssues()
    appendConnectionEvent(
      kind: .info,
      detail: "Daemon host bridge refreshed (revision \(manifest.revision))"
    )
  }

  /// Read the manifest file from disk and call `applyManifestRevision` if the
  /// host bridge state changed. This is the 10s fallback for when the
  /// DispatchSource watcher stops firing.
  ///
  /// No-op when the manifest is absent, undecodable, or bridge state is
  /// identical to what the store already has. Decoder is allocated once per
  /// call - this method only runs in the background probe task, never in a
  /// view body.
  func refreshBridgeStateFromManifest(at manifestURL: URL = HarnessMonitorPaths.manifestURL()) {
    guard
      let data = FileManager.default.contents(atPath: manifestURL.path)
    else { return }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let manifest = try? decoder.decode(DaemonManifest.self, from: data) else { return }
    guard daemonStatus?.manifest?.hostBridge != manifest.hostBridge else { return }
    applyManifestRevision(manifest)
  }

  private func mutateHostBridgeCapability(
    using client: any HarnessMonitorClientProtocol,
    capability: String,
    enabled: Bool,
    force: Bool
  ) async -> HostBridgeCapabilityMutationResult {
    do {
      let measuredStatus = try await measureHostBridgeCapabilityMutation(
        using: client,
        capability: capability,
        enabled: enabled,
        force: force
      )
      applyHostBridgeCapabilityMutationSuccess(
        capability: capability,
        enabled: enabled,
        status: measuredStatus.value
      )
      return .success
    } catch let apiError as HarnessMonitorAPIError {
      if case .server(let code, let message) = apiError, code == 409 {
        return .requiresForce(message)
      }
      if case .server(let code, _) = apiError, code == 404 {
        return await recoverMissingHostBridgeReconfigureRoute(
          capability: capability,
          enabled: enabled,
          force: force
        )
      }
      if case .server(let code, let message) = apiError,
        code == 400,
        message.localizedCaseInsensitiveContains("bridge is not running")
      {
        applyStoppedHostBridgeState()
        let friendlyMessage = "The shared host bridge is not running. Start it and try again."
        appendConnectionEvent(kind: .error, detail: friendlyMessage)
        presentFailureFeedback(friendlyMessage)
        return .failed
      }
      if case .server(let code, _) = apiError, code == 501 || code == 503 {
        markHostBridgeIssue(for: capability, statusCode: code)
      }
      presentFailureFeedback(apiError.localizedDescription)
      return .failed
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return .failed
    }
  }

  private func measureHostBridgeCapabilityMutation(
    using client: any HarnessMonitorClientProtocol,
    capability: String,
    enabled: Bool,
    force: Bool
  ) async throws -> MeasuredOperation<BridgeStatusReport> {
    try await Self.measureOperation {
      try await client.reconfigureHostBridge(
        request: HostBridgeReconfigureRequest(
          enable: enabled ? [capability] : [],
          disable: enabled ? [] : [capability],
          force: force
        )
      )
    }
  }

  private func applyHostBridgeCapabilityMutationSuccess(
    capability: String,
    enabled: Bool,
    status: BridgeStatusReport
  ) {
    recordRequestSuccess()
    clearHostBridgeIssue(for: capability)
    applyHostBridgeStatus(status)
    if capability == "agent-tui" && !enabled {
      cancelAgentTuiActionRefresh()
      selectedAgentTuis = []
      selectedAgentTui = nil
    }
    presentSuccessFeedback(hostBridgeActionLabel(for: capability, enabled: enabled))
  }

  private func applyStoppedHostBridgeState() {
    clearTransientHostBridgeIssues()
    if let daemonStatus {
      self.daemonStatus = daemonStatus.updating(hostBridge: HostBridgeManifest())
    }
  }

  private func recoverMissingHostBridgeReconfigureRoute(
    capability: String,
    enabled: Bool,
    force: Bool
  ) async -> HostBridgeCapabilityMutationResult {
    switch daemonOwnership {
    case .external:
      let message =
        "Connected daemon does not support live host bridge reconfiguration yet. "
        + "Restart `harness daemon dev` and try again."
      appendConnectionEvent(kind: .error, detail: message)
      presentFailureFeedback(message)
      return .failed
    case .managed:
      appendConnectionEvent(
        kind: .reconnecting,
        detail: "Restarting the managed daemon to pick up host bridge reconfigure support"
      )
      do {
        let recoveredClient = try await restartManagedDaemonForHostBridgeReconfigure()
        let measuredStatus = try await measureHostBridgeCapabilityMutation(
          using: recoveredClient,
          capability: capability,
          enabled: enabled,
          force: force
        )
        applyHostBridgeCapabilityMutationSuccess(
          capability: capability,
          enabled: enabled,
          status: measuredStatus.value
        )
        return .success
      } catch {
        presentFailureFeedback(error.localizedDescription)
        return .failed
      }
    }
  }

  private func restartManagedDaemonForHostBridgeReconfigure() async throws
    -> any HarnessMonitorClientProtocol
  {
    stopAllStreams()
    let staleClient = client
    client = nil
    if let staleClient {
      await staleClient.shutdown()
    }

    _ = try await daemonController.stopDaemon()
    let registrationState = try await daemonController.registerLaunchAgent()
    switch registrationState {
    case .enabled:
      break
    case .requiresApproval:
      throw DaemonControlError.commandFailed(
        "Launch agent needs approval in System Settings > General > Login Items."
      )
    case .notRegistered, .notFound:
      throw DaemonControlError.commandFailed("Launch agent registration did not complete.")
    }

    let refreshedClient = try await daemonController.awaitManifestWarmUp(
      timeout: bootstrapWarmUpTimeout
    )
    await connect(using: refreshedClient)
    guard connectionState == .online else {
      throw DaemonControlError.commandFailed(
        "The harness daemon did not become healthy before the timeout."
      )
    }
    return refreshedClient
  }

  private func hostBridgeActionLabel(for capability: String, enabled: Bool) -> String {
    let capabilityName =
      switch capability {
      case "agent-tui":
        "Agent TUI"
      case "codex":
        "Codex"
      default:
        capability.replacingOccurrences(of: "-", with: " ").capitalized
      }
    return enabled ? "Enabled \(capabilityName) host bridge" : "Disabled \(capabilityName) host bridge"
  }
}
