import Foundation

struct ValidatedAcpPermissionRequest {
  let requestID: String
  let toolCall: JSONValue
}

struct InvalidAcpPermissionRequestError: Error {
  let renderError: RenderableError
}

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
      createdAt: ISO8601DateFormatter().string(from: decision.createdAt),
      expiresAt: nil
    )
    return Self(
      decisionID: decision.id,
      summary: unavailableSummary,
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

  static func revalidatedDecodedPayload(
    _ decodedPayload: Self,
    decision: Decision
  ) -> Self {
    if let ownershipError = payloadOwnershipError(
      for: decodedPayload.rawBatch,
      decision: decision
    ) {
      return decodeFailure(for: decision, message: ownershipError)
    }
    let fallbackAgentID = normalizedAgentField(
      decision.agentID,
      fallback: "unknown-agent"
    )
    let agentID = normalizedAgentField(
      decodedPayload.agent.agentID,
      fallback: fallbackAgentID
    )
    let agentName = normalizedAgentField(
      decodedPayload.agent.agentName,
      fallback: decision.agentID ?? "Unknown Agent"
    )
    let revalidatedPayload = Self.make(
      batch: decodedPayload.rawBatch,
      agentID: agentID,
      agentName: agentName
    )
    return Self(
      decisionID: decision.id,
      summary: revalidatedPayload.summary,
      agent: AgentContext(
        agentID: agentID,
        agentName: agentName,
        managedAgentID: revalidatedPayload.agent.managedAgentID
      ),
      rawBatch: revalidatedPayload.rawBatch,
      renderableBatch: revalidatedPayload.renderableBatch,
      renderError: revalidatedPayload.renderError
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

  static func validatedRequest(
    _ request: AcpPermissionItem,
    batchSessionID: String,
    seenRequestIDs: inout Set<String>
  ) throws -> ValidatedAcpPermissionRequest {
    guard !request.requestId.isEmpty else {
      throw InvalidAcpPermissionRequestError(
        renderError: Self.invalidBatchError("One ACP permission item is missing a request id.")
      )
    }
    guard seenRequestIDs.insert(request.requestId).inserted else {
      throw InvalidAcpPermissionRequestError(
        renderError: Self.invalidBatchError("ACP permission items must have unique request ids.")
      )
    }
    guard request.sessionId == batchSessionID else {
      throw InvalidAcpPermissionRequestError(
        renderError: Self.invalidBatchError(
          "ACP permission items did not match the selected session."
        )
      )
    }
    guard case .object(let toolCallObject) = request.toolCall else {
      throw InvalidAcpPermissionRequestError(
        renderError: Self.invalidBatchError("ACP permission items must include a tool-call object.")
      )
    }
    if let toolCallContextError = Self.validateToolCallContext(in: toolCallObject) {
      throw InvalidAcpPermissionRequestError(renderError: toolCallContextError)
    }
    return ValidatedAcpPermissionRequest(
      requestID: request.requestId,
      toolCall: .object(toolCallObject)
    )
  }

  private static func normalizedAgentField(
    _ value: String?,
    fallback: String
  ) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func payloadOwnershipError(
    for batch: AcpPermissionBatch,
    decision: Decision
  ) -> String? {
    let expectedDecisionID = decisionID(for: batch.batchId)
    guard decision.id == expectedDecisionID else {
      return "Persisted ACP payload did not match the enclosing decision id."
    }

    let persistedSessionID =
      decision.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard persistedSessionID == batch.sessionId else {
      return "Persisted ACP payload did not match the enclosing decision session."
    }

    return nil
  }
}
