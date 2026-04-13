import Foundation

extension HarnessMonitorStore {
  public enum AgentTuiResizeFeedback: Sendable {
    case visible
    case silent
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

  public func fetchPersonas() async -> [AgentPersona] {
    guard let client else { return [] }
    return (try? await client.personas()) ?? []
  }

  @discardableResult
  public func startAgentTui(
    runtime: AgentTuiRuntime,
    name: String?,
    prompt: String?,
    projectDir: String? = nil,
    persona: String? = nil,
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
    let normalizedArgv =
      argv
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
          persona: persona,
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
    cols: Int,
    feedback: AgentTuiResizeFeedback = .visible
  ) async -> Bool {
    guard guardSessionActionsAvailable() else { return false }
    guard let client else { return false }
    guard rows > 0, cols > 0 else {
      presentFailureFeedback("Terminal size must be greater than zero.")
      return false
    }

    let actionName: String? =
      switch feedback {
      case .visible:
        "Agent TUI resized"
      case .silent:
        nil
      }

    return await mutateAgentTui(using: client, actionName: actionName) {
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
    selectedAgentTui =
      selectedAgentTuis.first(where: { $0.tuiId == tuiID })
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
      let sortedTuis = measuredTuis.value.canonicallySorted(roleByAgent: selectedSessionRoles())
        .tuis
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

      for _ in 0..<Self.agentTuiActionRefreshAttempts {
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
        // Keep the corrective GET alive for stale equal-or-older streaming snapshots.
        if (selectedAgentTui?.updatedAt ?? "") > baseline.updatedAt {
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
      let tuiId = baseline.tuiId
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "agent TUI post-action refresh failed for \(tuiId, privacy: .public): \(err, privacy: .public)"
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
      uniqueKeysWithValues: (selectedSession?.agents ?? []).map { ($0.agentId, $0.role) }
    )
  }
}
