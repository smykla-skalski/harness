import Foundation

extension AcpPermissionDecisionPayload {
  static func decodeFailure(
    for decision: Decision,
    message: String
  ) -> Self {
    let rawBatch = AcpPermissionBatch(
      batchId: decision.id.replacingOccurrences(of: "\(ruleID):", with: ""),
      acpId: decision.agentID ?? "unknown-managed-agent",
      sessionId: decision.sessionID ?? "",
      requests: [],
      createdAt: ISO8601DateFormatter().string(from: decision.createdAt)
    )
    return Self(
      decisionID: decision.id,
      summary: decision.summary,
      agent: AgentContext(
        agentID: decision.agentID ?? "unknown-agent",
        agentName: decision.agentID ?? "Unknown Agent",
        managedAgentID: rawBatch.acpId
      ),
      rawBatch: rawBatch,
      renderableBatch: nil,
      renderError: RenderableError(
        title: "ACP payload could not be rendered",
        message: message,
        recoverySuggestion: "Dismiss the decision and wait for the daemon to resend it."
      )
    )
  }

  static func summary(agentName: String, requestCount: Int) -> String {
    let suffix = requestCount == 1 ? "permission" : "permissions"
    return "\(agentName) requested \(requestCount) \(suffix)"
  }

  static func toolCallLabel(_ value: JSONValue, keys: [String]) -> String? {
    guard case .object(let object) = value else {
      return nil
    }
    for key in keys {
      guard case .string(let string)? = object[key], !string.isEmpty else {
        continue
      }
      return string
    }
    return nil
  }
}
