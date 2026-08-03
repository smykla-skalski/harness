import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func startDashboardTerminalAgent(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async -> DashboardTerminalStartOutcome {
    guard request.rows > 0, request.cols > 0 else {
      return rejectedDashboardTerminalStart("Terminal size must be greater than zero")
    }
    let runtime = request.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !runtime.isEmpty else {
      return rejectedDashboardTerminalStart("Terminal runtime cannot be empty")
    }
    let dashboardRequest = AgentTuiStartRequest(
      runtime: runtime,
      role: request.role,
      capabilities: request.capabilities,
      name: Self.dashboardTerminalValue(request.name),
      prompt: Self.dashboardTerminalValue(request.prompt),
      projectDir: Self.dashboardTerminalValue(request.projectDir),
      persona: request.persona,
      taskID: request.taskID,
      boardItemID: request.boardItemID,
      workflowExecutionID: request.workflowExecutionID,
      model: request.model,
      effort: request.effort,
      allowCustomModel: request.allowCustomModel,
      argv: request.argv.compactMap(Self.dashboardTerminalValue),
      rows: request.rows,
      cols: request.cols
    )
    guard let client else {
      return rejectedDashboardTerminalStart("Agent client is unavailable")
    }
    do {
      guard
        let snapshot = dashboardTerminalSnapshot(
          try await client.startManagedTerminalAgent(
            sessionID: sessionID,
            request: dashboardRequest
          ),
          expectedSessionID: sessionID,
          reportsFailure: false
        )
      else {
        return unknownDashboardTerminalStart(
          "The daemon returned an invalid managed terminal identity"
        )
      }
      presentSuccessFeedback("Terminal agent started")
      return .started(snapshot)
    } catch {
      let message = error.localizedDescription
      if let apiError = error as? HarnessMonitorAPIError,
        apiError.serverSemanticCode == "KSRCLI093"
      {
        return rejectedDashboardTerminalStart(message)
      }
      return unknownDashboardTerminalStart(message)
    }
  }

  public func dashboardTerminalAgentDetail(
    managedAgentID: String,
    sessionID: String,
    sessionAgentID: String?,
    checksMembership: Bool = true
  ) async -> DashboardTerminalAgentDetail {
    guard let client else {
      return DashboardTerminalAgentDetail(
        snapshot: nil,
        issues: ["Agent client is unavailable"]
      )
    }
    do {
      guard case .terminal(let snapshot) = try await client.managedAgent(agentID: managedAgentID)
      else {
        return DashboardTerminalAgentDetail(
          snapshot: nil,
          issues: ["Managed identity now belongs to another runtime"]
        )
      }
      guard snapshot.tuiId == managedAgentID else {
        return DashboardTerminalAgentDetail(
          snapshot: nil,
          issues: ["The daemon returned a different managed terminal identity"]
        )
      }
      var issues: [String] = []
      let isMember: Bool?
      if checksMembership, let sessionAgentID {
        do {
          let session = try await client.sessionDetail(id: sessionID, scope: "core")
          isMember = session.agents.contains { $0.agentId == sessionAgentID }
        } catch {
          isMember = nil
          issues.append("Membership unavailable: \(error.localizedDescription)")
        }
      } else {
        isMember = nil
      }
      return DashboardTerminalAgentDetail(
        snapshot: snapshot,
        isMember: isMember,
        issues: issues
      )
    } catch {
      return DashboardTerminalAgentDetail(
        snapshot: nil,
        issues: ["Managed terminal unavailable: \(error.localizedDescription)"]
      )
    }
  }

  @discardableResult
  public func sendDashboardTerminalInput(
    agentID: String,
    input: AgentTuiInput
  ) async -> AgentTuiSnapshot? {
    await dashboardTerminalSnapshotAction(success: nil, expectedAgentID: agentID) { client in
      try await client.sendManagedAgentInput(
        agentID: agentID,
        request: AgentTuiInputRequest(input: input)
      )
    }
  }

  @discardableResult
  public func sendDashboardTerminalInputSequence(
    agentID: String,
    inputs: [AgentTuiInput]
  ) async -> AgentTuiSnapshot? {
    guard !inputs.isEmpty else {
      presentFailureFeedback("Terminal input sequence cannot be empty")
      return nil
    }
    let sequence = AgentTuiInputSequence(
      steps: inputs.enumerated().map { index, input in
        AgentTuiInputSequenceStep(delayBeforeMs: index == 0 ? 0 : 10, input: input)
      }
    )
    do {
      let request = try AgentTuiInputRequest(sequence: sequence)
      return await dashboardTerminalSnapshotAction(
        success: nil,
        expectedAgentID: agentID
      ) { client in
        try await client.sendManagedAgentInput(agentID: agentID, request: request)
      }
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func resizeDashboardTerminalAgent(
    agentID: String,
    rows: Int,
    cols: Int,
    feedback: AgentTuiResizeFeedback = .visible
  ) async -> AgentTuiSnapshot? {
    let reportsFailure =
      switch feedback {
      case .visible: true
      case .silent: false
      }
    guard rows > 0, cols > 0 else {
      if reportsFailure { presentFailureFeedback("Terminal size must be greater than zero") }
      return nil
    }
    return await dashboardTerminalSnapshotAction(
      success: nil,
      expectedAgentID: agentID,
      reportsFailure: reportsFailure
    ) { client in
      try await client.resizeManagedAgent(
        agentID: agentID,
        request: AgentTuiResizeRequest(rows: rows, cols: cols)
      )
    }
  }

  @discardableResult
  public func stopDashboardTerminalAgent(agentID: String) async -> AgentTuiSnapshot? {
    await dashboardTerminalSnapshotAction(
      success: "Terminal agent stopped",
      expectedAgentID: agentID
    ) { client in
      try await client.stopManagedAgent(agentID: agentID)
    }
  }

  @discardableResult
  public func sendDashboardTerminalSignal(
    sessionID: String,
    sessionAgentID: String,
    command: String,
    message: String,
    actionHint: String?
  ) async -> Bool {
    let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, !message.isEmpty else {
      presentFailureFeedback("Signal command and message are required")
      return false
    }
    return await sendSignal(
      sessionID: sessionID,
      request: SignalSendRequest(
        actor: "harness-app",
        agentId: sessionAgentID,
        command: command,
        message: message,
        actionHint: Self.dashboardTerminalValue(actionHint)
      )
    )
  }

  @discardableResult
  public func removeDashboardTerminalMembership(
    sessionID: String,
    sessionAgentID: String
  ) async -> Bool {
    guard let client else {
      presentFailureFeedback("Agent client is unavailable")
      return false
    }
    do {
      _ = try await client.removeAgent(
        sessionID: sessionID,
        agentID: sessionAgentID,
        request: AgentRemoveRequest(actor: "harness-dashboard")
      )
      presentSuccessFeedback("Terminal agent removed")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}

extension HarnessMonitorStore {
  private func dashboardTerminalSnapshotAction(
    success: String?,
    expectedSessionID: String? = nil,
    expectedAgentID: String? = nil,
    reportsFailure: Bool = true,
    operation: (any HarnessMonitorClientProtocol) async throws -> ManagedAgentSnapshot
  ) async -> AgentTuiSnapshot? {
    guard let client else {
      if reportsFailure { presentFailureFeedback("Agent client is unavailable") }
      return nil
    }
    do {
      guard
        let snapshot = dashboardTerminalSnapshot(
          try await operation(client),
          expectedSessionID: expectedSessionID,
          expectedAgentID: expectedAgentID,
          reportsFailure: reportsFailure
        )
      else { return nil }
      if let success { presentSuccessFeedback(success) }
      return snapshot
    } catch {
      if reportsFailure { presentFailureFeedback(error.localizedDescription) }
      return nil
    }
  }

  private func dashboardTerminalSnapshot(
    _ managed: ManagedAgentSnapshot,
    expectedSessionID: String? = nil,
    expectedAgentID: String? = nil,
    reportsFailure: Bool
  ) -> AgentTuiSnapshot? {
    guard case .terminal(let snapshot) = managed else {
      if reportsFailure {
        presentFailureFeedback("Managed identity now belongs to another runtime")
      }
      return nil
    }
    if let expectedSessionID, snapshot.sessionId != expectedSessionID {
      if reportsFailure {
        presentFailureFeedback("Terminal start returned a different workspace identity")
      }
      return nil
    }
    if let expectedAgentID, snapshot.tuiId != expectedAgentID {
      if reportsFailure {
        presentFailureFeedback("Terminal action returned a different managed identity")
      }
      return nil
    }
    return snapshot
  }

  private func rejectedDashboardTerminalStart(
    _ message: String
  ) -> DashboardTerminalStartOutcome {
    presentFailureFeedback(message)
    return .rejected(message)
  }

  private func unknownDashboardTerminalStart(
    _ message: String
  ) -> DashboardTerminalStartOutcome {
    presentFailureFeedback(message)
    return .unknown(message)
  }

  nonisolated private static func dashboardTerminalValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
