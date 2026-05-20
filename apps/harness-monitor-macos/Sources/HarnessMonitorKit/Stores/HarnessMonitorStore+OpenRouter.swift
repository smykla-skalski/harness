import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func startOpenRouterRun(
    prompt: String,
    model: String?,
    displayName: String? = nil,
    sessionAgentID: String? = nil,
    temperature: Float? = nil,
    maxTokens: UInt32? = nil,
    reasoningEffort: String? = nil,
    projectDir: String? = nil,
    sessionID: String? = nil
  ) async -> OpenRouterRunSnapshot? {
    guard
      let action = prepareSessionAction(
        named: "Start OpenRouter session",
        sessionID: sessionID ?? selectedSessionID
      )
    else {
      return nil
    }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = OpenRouterStartRequest(
      model: model,
      prompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
      sessionAgentId: sessionAgentID,
      displayName: displayName,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningEffort: reasoningEffort,
      projectDir: projectDir
    )
    do {
      let snapshot = try await action.client.startManagedOpenRouterAgent(
        sessionID: action.sessionID,
        request: request
      )
      return snapshot.openRouter
    } catch {
      presentFailureFeedback(
        "Failed to start OpenRouter session: \(error.localizedDescription)"
      )
      return nil
    }
  }

  @discardableResult
  public func promptOpenRouterRun(
    runID: String,
    prompt: String
  ) async -> OpenRouterRunSnapshot? {
    guard let client else { return nil }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      presentFailureFeedback("OpenRouter prompt cannot be empty.")
      return nil
    }
    do {
      return try await client.promptManagedOpenRouterAgent(
        managedAgentID: runID,
        prompt: trimmedPrompt
      )
    } catch {
      presentFailureFeedback(
        "Failed to send prompt to OpenRouter session: \(error.localizedDescription)"
      )
      return nil
    }
  }

  @discardableResult
  public func cancelOpenRouterRun(runID: String) async -> OpenRouterRunSnapshot? {
    guard let client else { return nil }
    do {
      return try await client.cancelManagedOpenRouterAgent(managedAgentID: runID)
    } catch {
      presentFailureFeedback(
        "Failed to cancel OpenRouter session: \(error.localizedDescription)"
      )
      return nil
    }
  }

  public func fetchOpenRouterModels() async -> [OpenRouterModelEntry] {
    guard let client else { return [] }
    do {
      return try await client.listOpenRouterModels().data
    } catch {
      return []
    }
  }

  @discardableResult
  public func resolveOpenRouterPermissionBatch(
    runID: String,
    batchID: String,
    decision: AcpPermissionDecision
  ) async -> ManagedAgentSnapshot? {
    guard let client else { return nil }
    do {
      return try await client.resolveManagedAcpPermission(
        agentID: runID,
        batchID: batchID,
        decision: decision
      )
    } catch {
      presentFailureFeedback(
        "Failed to resolve permission batch: \(error.localizedDescription)"
      )
      return nil
    }
  }
}
