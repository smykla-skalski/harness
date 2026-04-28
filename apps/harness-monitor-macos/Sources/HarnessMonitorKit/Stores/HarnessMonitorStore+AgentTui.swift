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

  public func fetchRuntimeModelCatalogs() async -> [RuntimeModelCatalog] {
    guard let client else { return [] }
    return (try? await client.runtimeModelCatalogs()) ?? []
  }

  @discardableResult
  public func startAgentTui(
    runtime: AgentTuiRuntime,
    role: SessionRole = .worker,
    name: String?,
    prompt: String?,
    projectDir: String? = nil,
    persona: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false,
    argv: [String] = [],
    rows: Int,
    cols: Int
  ) async -> Bool {
    let actionName = "Agents started"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
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
      using: action.client,
      actionName: actionName,
      selectUpdatedSnapshot: true
    ) {
      try await action.client.startAgentTui(
        sessionID: action.sessionID,
        request: AgentTuiStartRequest(
          runtime: runtime.rawValue,
          role: role,
          name: trimmedName?.isEmpty == false ? trimmedName : nil,
          prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
          projectDir: trimmedProjectDir?.isEmpty == false ? trimmedProjectDir : nil,
          persona: persona,
          model: model,
          effort: effort,
          allowCustomModel: allowCustomModel,
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
    request: AgentTuiInputRequest,
    showSuccessFeedback: Bool = true
  ) async -> Bool {
    let actionName = showSuccessFeedback ? "Agents input sent" : nil
    if let actionName {
      guard prepareSelectedSessionAction(named: actionName) != nil else { return false }
    } else {
      guard areSelectedSessionActionsAvailable else { return false }
    }
    guard let client else { return false }

    return await mutateAgentTui(
      using: client,
      actionName: actionName,
      mutation: {
      try await client.sendAgentTuiInput(
        tuiID: tuiID,
        request: request
      )
      },
      staleTuiID: tuiID
    )
  }

  @discardableResult
  public func sendAgentTuiInput(
    tuiID: String,
    input: AgentTuiInput,
    showSuccessFeedback: Bool = true
  ) async -> Bool {
    await sendAgentTuiInput(
      tuiID: tuiID,
      request: AgentTuiInputRequest(input: input),
      showSuccessFeedback: showSuccessFeedback
    )
  }

  @discardableResult
  public func resizeAgentTui(
    tuiID: String,
    rows: Int,
    cols: Int,
    feedback: AgentTuiResizeFeedback = .visible
  ) async -> Bool {
    let actionName: String? =
      switch feedback {
      case .visible:
        "Agents resized"
      case .silent:
        nil
      }
    if let actionName {
      guard prepareSelectedSessionAction(named: actionName) != nil else { return false }
    } else {
      guard areSelectedSessionActionsAvailable else { return false }
    }
    guard let client else { return false }
    guard rows > 0, cols > 0 else {
      presentFailureFeedback("Terminal size must be greater than zero.")
      return false
    }

    return await mutateAgentTui(
      using: client,
      actionName: actionName,
      mutation: {
      try await client.resizeAgentTui(
        tuiID: tuiID,
        request: AgentTuiResizeRequest(rows: rows, cols: cols)
      )
      },
      staleTuiID: tuiID
    )
  }

  @discardableResult
  public func stopAgentTui(tuiID: String) async -> Bool {
    let actionName = "Agents stopped"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }

    return await mutateAgentTui(
      using: action.client,
      actionName: actionName,
      mutation: {
      try await action.client.stopAgentTui(tuiID: tuiID)
      },
      staleTuiID: tuiID
    )
  }

  public func selectAgentTui(tuiID: String?) {
    let previousTuiID = selectedAgentTui?.tuiId
    guard let tuiID else {
      assignSelectedAgentTui(preferredAgentTui(from: selectedAgentTuis))
      if selectedAgentTui?.tuiId != previousTuiID {
        cancelAgentTuiActionRefresh()
      }
      return
    }
    assignSelectedAgentTui(
      selectedAgentTuis.first(where: { $0.tuiId == tuiID })
        ?? preferredAgentTui(from: selectedAgentTuis)
    )
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
    assignAgentTuis([], selected: nil)
  }
  func applyAgentTui(_ tui: AgentTuiSnapshot) {
    guard tui.sessionId == selectedSessionID else {
      return
    }

    clearHostBridgeIssue(for: "agent-tui")
    let tuis = upsertingAgentTui(tui, into: selectedAgentTuis)
    let preferred =
      selectedAgentTui?.tuiId == tui.tuiId || selectedAgentTui == nil
      ? tui : preferredAgentTui(from: tuis)
    assignAgentTuis(tuis, selected: preferred)
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
      assignAgentTuis(sortedTuis, selected: preferredAgentTui(from: sortedTuis))
      return true
    } catch {
      return applyAgentTuiError(error, selectedSessionID: sessionID)
    }
  }
  func recoverSelectedAgentTuisAfterReconnect(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async {
    do {
      let measuredTuis = try await Self.measureOperation {
        try await client.agentTuis(sessionID: sessionID)
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return
      }
      clearHostBridgeIssue(for: "agent-tui")
      let sortedTuis = measuredTuis.value.canonicallySorted(roleByAgent: selectedSessionRoles())
        .tuis
      assignAgentTuis(sortedTuis, selected: preferredAgentTui(from: sortedTuis))
    } catch {
      guard selectedSessionID == sessionID else {
        return
      }
      if let apiError = error as? HarnessMonitorAPIError,
        case .server(let code, _) = apiError,
        code == 501
      {
        markHostBridgeIssue(for: "agent-tui", statusCode: code)
      }
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect terminal agent refresh failed: \(err, privacy: .public)"
      )
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
      return applyAgentTuiError(error, selectedSessionID: selectedSessionID, staleTuiID: tuiID)
    }
  }
  private func mutateAgentTui(
    using client: any HarnessMonitorClientProtocol,
    actionName: String? = nil,
    selectUpdatedSnapshot: Bool = false,
    mutation: @escaping @Sendable () async throws -> AgentTuiSnapshot,
    staleTuiID: String? = nil
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
      return applyAgentTuiError(
        error,
        selectedSessionID: selectedSessionID,
        staleTuiID: staleTuiID
      )
    }
  }
  private func applyAgentTuiError(
    _ error: any Error,
    selectedSessionID: String?,
    staleTuiID: String? = nil
  ) -> Bool {
    guard selectedSessionID == self.selectedSessionID else {
      return false
    }
    if let staleTuiID, reconcileStaleManagedAgentError(error, tuiID: staleTuiID) {
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
        "terminal agent post-action refresh failed for \(tuiId, privacy: .public): \(err, privacy: .public)"
      )
      if reconcileStaleManagedAgentError(error, tuiID: baseline.tuiId) {
        return true
      }
      return true
    }
  }
  private func reconcileStaleManagedAgentError(
    _ error: any Error,
    tuiID: String
  ) -> Bool {
    guard isStaleManagedAgentError(error, tuiID: tuiID) else {
      return false
    }
    cancelAgentTuiActionRefresh(for: tuiID)
    let remainingTuis = selectedAgentTuis.filter { $0.tuiId != tuiID }
    assignAgentTuis(remainingTuis, selected: preferredAgentTui(from: remainingTuis))
    return true
  }
  private func isStaleManagedAgentError(
    _ error: any Error,
    tuiID: String
  ) -> Bool {
    guard let apiError = error as? HarnessMonitorAPIError,
      case .server(let code, _) = apiError,
      code == 400 || code == 404
    else {
      return false
    }
    let message = apiError.serverMessage ?? error.localizedDescription
    return
      apiError.serverSemanticCode == "KSRCLI090"
      || message.contains("managed agent '\(tuiID)' not found")
      || message.contains("terminal agent '\(tuiID)' not found")
      || message.contains("terminal agent '\(tuiID)' is not active")
  }
  private func preferredAgentTui(from tuis: [AgentTuiSnapshot]) -> AgentTuiSnapshot? {
    if let selectedTuiID = selectedAgentTui?.tuiId,
      let selectedTui = tuis.first(where: { $0.tuiId == selectedTuiID })
    {
      return selectedTui
    }
    return tuis.first(where: { $0.status.isActive }) ?? tuis.first
  }
}
