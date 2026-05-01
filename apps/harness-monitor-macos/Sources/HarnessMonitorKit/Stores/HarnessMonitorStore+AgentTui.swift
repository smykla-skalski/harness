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
    cols: Int,
    sessionID: String? = nil
  ) async -> Bool {
    await startAgentTuiSnapshot(
      runtime: runtime,
      role: role,
      name: name,
      prompt: prompt,
      projectDir: projectDir,
      persona: persona,
      model: model,
      effort: effort,
      allowCustomModel: allowCustomModel,
      argv: argv,
      rows: rows,
      cols: cols,
      sessionID: sessionID
    ) != nil
  }

  @discardableResult
  public func startAgentTuiSnapshot(
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
    cols: Int,
    sessionID: String? = nil
  ) async -> AgentTuiSnapshot? {
    let actionName = "Agents started"
    guard
      let action = prepareSessionAction(
        named: actionName,
        sessionID: sessionID ?? selectedSessionID
      )
    else {
      return nil
    }
    guard rows > 0, cols > 0 else {
      presentFailureFeedback("Terminal size must be greater than zero.")
      return nil
    }

    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProjectDir = projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedArgv =
      argv
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    return await mutateAgentTuiSnapshot(
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
}
