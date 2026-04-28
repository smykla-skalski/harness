import Foundation

extension HarnessMonitorStore {
  public func fetchAcpAgentDescriptors() async -> [AcpAgentDescriptor] {
    guard let client else { return [] }
    return (try? await client.acpAgentDescriptors()) ?? []
  }

  public func fetchRuntimeProbeResults() async -> AcpRuntimeProbeResponse? {
    guard let client else { return nil }
    return try? await client.runtimeProbeResults()
  }

  @discardableResult
  public func startAcpAgent(
    agentID: String,
    prompt: String?,
    projectDir: String? = nil
  ) async -> AcpAgentSnapshot? {
    let actionName = "Agent started"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return nil }
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProjectDir = projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let measuredSnapshot = try await Self.measureOperation {
        try await action.client.startManagedAcpAgent(
          sessionID: action.sessionID,
          request: AcpAgentStartRequest(
            agent: agentID,
            prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
            projectDir: trimmedProjectDir?.isEmpty == false ? trimmedProjectDir : nil
          )
        )
      }
      recordRequestSuccess()
      guard case .acp(let snapshot) = measuredSnapshot.value else {
        presentFailureFeedback("Agent controller returned an unexpected response.")
        return nil
      }
      presentSuccessFeedback(actionName)
      return snapshot
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
