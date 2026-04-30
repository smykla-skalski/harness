import Foundation

extension AcpPermissionDecisionPayload {
  static func validate(
    batch: AcpPermissionBatch
  ) -> (batch: RenderableBatch?, error: RenderableError?) {
    guard !batch.batchId.isEmpty else {
      return (nil, invalidBatchError("The daemon sent an ACP batch without a batch id."))
    }
    guard !batch.sessionId.isEmpty else {
      return (nil, invalidBatchError("The daemon sent an ACP batch without a session id."))
    }
    guard !batch.acpId.isEmpty else {
      return (nil, invalidBatchError("The daemon sent an ACP batch without a managed agent id."))
    }
    guard !batch.requests.isEmpty else {
      return (nil, invalidBatchError("The ACP batch does not contain any permission requests."))
    }
    guard batch.requests.count <= maximumRequestCount else {
      return (
        nil,
        invalidBatchError(
          "The ACP batch exceeded the supported \(maximumRequestCount)-request limit."
        )
      )
    }

    var requests: [RenderableBatch.Request] = []
    requests.reserveCapacity(batch.requests.count)
    var seenRequestIDs = Set<String>()

    for request in batch.requests {
      let validatedPermissionRequest: ValidatedAcpPermissionRequest
      do {
        validatedPermissionRequest = try Self.validatedRequest(
          request,
          batchSessionID: batch.sessionId,
          seenRequestIDs: &seenRequestIDs
        )
      } catch let error as InvalidAcpPermissionRequestError {
        return (nil, error.renderError)
      } catch {
        return (nil, invalidBatchError("ACP permission items could not be rendered."))
      }
      let title =
        toolCallLabel(
          validatedPermissionRequest.toolCall,
          keys: ["kind", "name", "tool"]
        ) ?? "Tool call"
      let detail =
        toolCallLabel(validatedPermissionRequest.toolCall, keys: ["path", "command"])
        ?? compactJSON(validatedPermissionRequest.toolCall)
      let breadcrumb =
        toolCallLabel(validatedPermissionRequest.toolCall, keys: ["kind", "tool", "name"])
        ?? title
      requests.append(
        RenderableBatch.Request(
          id: validatedPermissionRequest.requestID,
          title: title,
          detail: detail,
          breadcrumb: breadcrumb
        )
      )
    }

    return (RenderableBatch(batch: batch, requests: requests), nil)
  }

  static func validateToolCallContext(
    in toolCallObject: [String: JSONValue]
  ) -> RenderableError? {
    guard
      let toolCallContext = toolCallObject["tool_call_context"] ?? toolCallObject["toolCallContext"]
    else {
      return nil
    }
    guard case .object(let toolCallContextObject) = toolCallContext else {
      return invalidBatchError("ACP tool_call_context must be an object when provided.")
    }

    let identifierKeys = [
      "tool_call_id",
      "toolCallId",
      "invocation_id",
      "invocationId",
      "id",
    ]
    let hasIdentifier = identifierKeys.contains { key in
      guard case .string(let value)? = toolCallContextObject[key] else {
        return false
      }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard hasIdentifier else {
      return invalidBatchError("ACP tool_call_context is missing a tool-call identifier.")
    }
    return nil
  }

  static func invalidBatchError(_ message: String) -> RenderableError {
    RenderableError(
      title: "ACP payload could not be rendered",
      message: message,
      recoverySuggestion: "Refresh the session or wait for a fresh ACP permission request."
    )
  }

  private static func compactJSON(_ value: JSONValue) -> String {
    guard
      let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "Permission request"
    }
    return string
  }

  static func suggestedAction(id: String, title: String) -> SuggestedAction {
    SuggestedAction(
      id: id,
      title: title,
      kind: .custom,
      payloadJSON: "{\"action\":\"\(id)\"}"
    )
  }
}
