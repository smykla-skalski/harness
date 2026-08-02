import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func startDashboardCodexAgent(
    sessionID: String,
    request: CodexRunRequest
  ) async -> CodexRunSnapshot? {
    let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      presentFailureFeedback("Codex prompt cannot be empty")
      return nil
    }
    let dashboardRequest = CodexRunRequest(
      actor: "harness-dashboard",
      prompt: trimmed,
      mode: request.mode,
      name: request.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      model: request.model,
      effort: request.effort,
      allowCustomModel: request.allowCustomModel
    )
    return await dashboardCodexSnapshotAction(success: "Codex agent started") { client in
      try await client.startManagedCodexAgent(sessionID: sessionID, request: dashboardRequest)
    }
  }

  public func dashboardCodexAgentDetail(
    managedAgentID: String,
    sessionID: String,
    sessionAgentID: String?
  ) async -> DashboardCodexAgentDetail {
    guard let client else {
      return DashboardCodexAgentDetail(
        run: nil,
        inspect: nil,
        transcript: [],
        issues: ["Agent client is unavailable"]
      )
    }

    async let managed = Self.dashboardCodexManagedAgent(client, managedAgentID)
    async let inspect = Self.dashboardCodexInspect(client, sessionID)
    async let transcript = Self.dashboardCodexTranscript(client, sessionID)
    let (managedResult, inspectResult, transcriptResult) = await (managed, inspect, transcript)

    var issues: [String] = []
    let run = managedResult.value(addingFailureTo: &issues)
    let inspectResponse = inspectResult.value(addingFailureTo: &issues)
    let transcriptResponse = transcriptResult.value(addingFailureTo: &issues)
    let inspectSnapshot = inspectResponse?.agents.first { $0.runId == managedAgentID }
    if inspectResponse != nil, inspectSnapshot == nil {
      issues.append("Codex inspect did not include this managed identity")
    }
    let transcriptEntries = Self.dashboardCodexTranscriptEntries(
      transcriptResponse?.entries ?? [],
      managedAgentID: managedAgentID,
      sessionAgentID: sessionAgentID
    )
    return DashboardCodexAgentDetail(
      run: run,
      inspect: inspectSnapshot,
      transcript: transcriptEntries,
      issues: issues
    )
  }

  @discardableResult
  public func steerDashboardCodexAgent(
    agentID: String,
    prompt: String
  ) async -> CodexRunSnapshot? {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      presentFailureFeedback("Codex context cannot be empty")
      return nil
    }
    return await dashboardCodexSnapshotAction(success: "Codex context sent") { client in
      try await client.steerManagedCodexAgent(
        agentID: agentID,
        request: CodexSteerRequest(prompt: trimmed)
      )
    }
  }

  @discardableResult
  public func interruptDashboardCodexAgent(agentID: String) async -> CodexRunSnapshot? {
    await dashboardCodexSnapshotAction(success: "Codex run interrupted") { client in
      try await client.interruptManagedCodexAgent(agentID: agentID)
    }
  }

  @discardableResult
  public func stopDashboardCodexAgent(agentID: String) async -> CodexRunSnapshot? {
    await dashboardCodexSnapshotAction(success: "Codex agent stopped") { client in
      try await client.stopManagedAgent(agentID: agentID)
    }
  }

  @discardableResult
  public func resolveDashboardCodexApproval(
    agentID: String,
    approvalID: String,
    decision: CodexApprovalDecision
  ) async -> CodexRunSnapshot? {
    await dashboardCodexSnapshotAction(success: "Codex approval resolved") { client in
      try await client.resolveManagedCodexApproval(
        agentID: agentID,
        approvalID: approvalID,
        request: CodexApprovalDecisionRequest(decision: decision)
      )
    }
  }
}

private enum DashboardCodexLoad<Value: Sendable>: Sendable {
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
  nonisolated private static func dashboardCodexManagedAgent(
    _ client: any HarnessMonitorClientProtocol,
    _ managedAgentID: String
  ) async -> DashboardCodexLoad<CodexRunSnapshot> {
    do {
      guard case .codex(let snapshot) = try await client.managedAgent(agentID: managedAgentID)
      else {
        return .failure("Managed identity now belongs to another runtime")
      }
      return .success(snapshot)
    } catch {
      return .failure("Managed agent unavailable: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardCodexInspect(
    _ client: any HarnessMonitorClientProtocol,
    _ sessionID: String
  ) async -> DashboardCodexLoad<CodexAgentInspectResponse> {
    do {
      let response = try await client.codexInspect(sessionID: sessionID)
      guard response.available else {
        return .failure(response.issueMessage ?? "Codex inspect is unavailable")
      }
      return .success(response)
    } catch {
      return .failure("Codex inspect failed: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardCodexTranscript(
    _ client: any HarnessMonitorClientProtocol,
    _ sessionID: String
  ) async -> DashboardCodexLoad<CodexTranscriptResponse> {
    do {
      return .success(try await client.codexTranscript(sessionID: sessionID))
    } catch {
      return .failure("Transcript unavailable: \(error.localizedDescription)")
    }
  }

  nonisolated private static func dashboardCodexTranscriptEntries(
    _ entries: [TimelineEntry],
    managedAgentID: String,
    sessionAgentID: String?
  ) -> [TimelineEntry] {
    var byID: [String: TimelineEntry] = [:]
    for entry in entries {
      let matches: Bool
      if let identity = entry.codexTimelineIdentityMetadata() {
        matches = identity.runID == managedAgentID
      } else {
        matches = sessionAgentID != nil && entry.agentId == sessionAgentID
      }
      if matches { byID[entry.entryId] = entry }
    }
    return byID.values.sorted {
      if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
      return $0.entryId < $1.entryId
    }
  }

  private func dashboardCodexSnapshotAction(
    success: String,
    operation: (any HarnessMonitorClientProtocol) async throws -> ManagedAgentSnapshot
  ) async -> CodexRunSnapshot? {
    guard let client else {
      presentFailureFeedback("Agent client is unavailable")
      return nil
    }
    do {
      guard case .codex(let snapshot) = try await operation(client) else {
        presentFailureFeedback("Managed identity now belongs to another runtime")
        return nil
      }
      applyCodexRun(snapshot)
      presentSuccessFeedback(success)
      return snapshot
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
