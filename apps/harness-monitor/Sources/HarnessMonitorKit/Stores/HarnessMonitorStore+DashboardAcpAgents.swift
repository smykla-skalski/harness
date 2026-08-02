import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func startDashboardAcpAgent(
    descriptorID: AcpDescriptorID,
    sessionID: String,
    projectDirectory: String,
    name: String?,
    prompt: String?
  ) async -> AcpAgentSnapshot? {
    await startAcpAgent(
      descriptorID: descriptorID,
      role: .worker,
      name: name,
      prompt: prompt,
      projectDir: projectDirectory,
      recordPermissions: true,
      sessionID: sessionID
    )
  }

  public func dashboardAcpAgentDetail(
    managedAgentID: String,
    sessionID: String,
    sessionAgentID: String?,
    projectDirectory: String
  ) async -> DashboardAcpAgentDetail {
    guard let client else {
      return DashboardAcpAgentDetail(
        agent: nil,
        inspect: nil,
        transcript: [],
        providerSessions: [],
        issues: ["Agent client is unavailable"]
      )
    }

    async let managed = Self.dashboardAcpManagedAgent(client, managedAgentID)
    async let inspect = Self.dashboardAcpInspect(client, sessionID)
    async let transcript = Self.dashboardAcpTranscript(client, sessionID)
    let (managedResult, inspectResult, transcriptResult) = await (managed, inspect, transcript)

    var issues: [String] = []
    let agent = managedResult.value(addingFailureTo: &issues)
    let inspectResponse = inspectResult.value(addingFailureTo: &issues)
    let transcriptResponse = transcriptResult.value(addingFailureTo: &issues)
    let inspectSnapshot = inspectResponse?.agents.first { $0.managedAgentID == managedAgentID }
    let transcriptEntries =
      transcriptResponse?.entries.filter { entry in
        guard let sessionAgentID else { return false }
        return entry.agentId == sessionAgentID
      } ?? []

    var providerSessions: [AcpProviderSession] = []
    if inspectSnapshot?.handshake?.supportsSessionList == true {
      let sessions = await Self.dashboardAcpSessions(client, managedAgentID, projectDirectory)
      providerSessions = sessions.value(addingFailureTo: &issues)?.sessions ?? []
    }

    return DashboardAcpAgentDetail(
      agent: agent,
      inspect: inspectSnapshot,
      transcript: transcriptEntries,
      providerSessions: providerSessions,
      issues: issues
    )
  }

  @discardableResult
  public func promptDashboardAcpAgent(agentID: String, prompt: String) async -> AcpAgentSnapshot? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      presentFailureFeedback("Prompt cannot be empty")
      return nil
    }
    return await dashboardAcpSnapshotAction(success: "Prompt sent") { client in
      try await client.promptManagedAcpAgent(agentID: agentID, prompt: trimmed)
    }
  }

  @discardableResult
  public func stopDashboardAcpAgent(agentID: String) async -> AcpAgentSnapshot? {
    await dashboardAcpSnapshotAction(success: "Agent stopped") { client in
      try await client.stopManagedAcpAgent(agentID: agentID)
    }
  }

  public func logoutDashboardAcpAgent(agentID: String) async -> Bool {
    await dashboardAcpAcknowledgedAction(success: "Provider logged out") { client in
      try await client.logoutManagedAcpAgent(agentID: agentID)
    }
  }

  public func closeDashboardAcpSession(agentID: String, sessionID: String) async -> Bool {
    await dashboardAcpAcknowledgedAction(success: "Provider session closed") { client in
      try await client.closeManagedAcpSession(agentID: agentID, sessionID: sessionID)
    }
  }

  public func deleteDashboardAcpSession(agentID: String, sessionID: String) async -> Bool {
    await dashboardAcpAcknowledgedAction(success: "Provider session deleted") { client in
      try await client.deleteManagedAcpSession(agentID: agentID, sessionID: sessionID)
    }
  }
}

private enum DashboardAcpLoad<Value: Sendable>: Sendable {
  case success(Value)
  case failure(String)

  func value(addingFailureTo issues: inout [String]) -> Value? {
    switch self {
    case .success(let value): return value
    case .failure(let message):
      issues.append(message)
      return nil
    }
  }
}

extension HarnessMonitorStore {
  nonisolated private static func dashboardAcpManagedAgent(
    _ client: any HarnessMonitorClientProtocol,
    _ managedAgentID: String
  ) async -> DashboardAcpLoad<AcpAgentSnapshot> {
    do {
      guard case .acp(let snapshot) = try await client.managedAgent(agentID: managedAgentID) else {
        return .failure("Managed identity now belongs to another runtime")
      }
      return .success(snapshot)
    } catch {
      return .failure("Managed agent unavailable: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardAcpInspect(
    _ client: any HarnessMonitorClientProtocol,
    _ sessionID: String
  ) async -> DashboardAcpLoad<AcpAgentInspectResponse> {
    do {
      let response = try await client.acpInspect(sessionID: sessionID)
      guard response.available else {
        return .failure(response.issueMessage ?? "ACP inspect is unavailable")
      }
      return .success(response)
    } catch {
      return .failure("ACP inspect failed: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardAcpTranscript(
    _ client: any HarnessMonitorClientProtocol,
    _ sessionID: String
  ) async -> DashboardAcpLoad<AcpTranscriptResponse> {
    do {
      return .success(try await client.acpTranscript(sessionID: sessionID))
    } catch {
      return .failure("Transcript unavailable: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardAcpSessions(
    _ client: any HarnessMonitorClientProtocol,
    _ managedAgentID: String,
    _ projectDirectory: String
  ) async -> DashboardAcpLoad<AcpProviderSessionPage> {
    do {
      return .success(
        try await client.managedAcpSessions(
          agentID: managedAgentID,
          cwd: projectDirectory,
          cursor: nil
        )
      )
    } catch {
      return .failure("Provider sessions unavailable: \(error.localizedDescription)")
    }
  }

  private func dashboardAcpSnapshotAction(
    success: String,
    operation: (any HarnessMonitorClientProtocol) async throws -> ManagedAgentSnapshot
  ) async -> AcpAgentSnapshot? {
    guard let client else {
      presentFailureFeedback("Agent client is unavailable")
      return nil
    }
    do {
      guard case .acp(let snapshot) = try await operation(client) else {
        presentFailureFeedback("Managed identity now belongs to another runtime")
        return nil
      }
      _ = applyAcpAgent(snapshot)
      presentSuccessFeedback(success)
      return snapshot
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  private func dashboardAcpAcknowledgedAction(
    success: String,
    operation: (any HarnessMonitorClientProtocol) async throws -> Void
  ) async -> Bool {
    guard let client else {
      presentFailureFeedback("Agent client is unavailable")
      return false
    }
    do {
      try await operation(client)
      presentSuccessFeedback(success)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
