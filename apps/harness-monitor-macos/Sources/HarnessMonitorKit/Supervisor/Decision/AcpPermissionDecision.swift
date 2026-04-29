import Foundation

public struct RenderableError: Codable, Equatable, Sendable {
  public let title: String
  public let message: String
  public let recoverySuggestion: String?

  public init(
    title: String,
    message: String,
    recoverySuggestion: String? = nil
  ) {
    self.title = title
    self.message = message
    self.recoverySuggestion = recoverySuggestion
  }
}

public enum AcpPermissionDecisionActionID {
  public static let approve = "approve"
  public static let approveSelected = "approve-selected"
  public static let approveAll = "approve-all"
  public static let deny = "deny"
  public static let denyAll = "deny-all"

  public static func isDenyAction(_ actionID: String) -> Bool {
    actionID == deny || actionID == denyAll
  }
}

public enum AcpPermissionDecisionActionError: LocalizedError, Equatable, Sendable {
  case emptySelection
  case unknownAction(String)

  public var errorDescription: String? {
    switch self {
    case .emptySelection:
      "Select at least one permission before approving."
    case .unknownAction(let actionID):
      "Unknown ACP permission action: \(actionID)"
    }
  }
}

/// Typed ACP overlay on top of the persisted `Decision` row contract.
///
/// The payload stores the raw daemon batch plus a validated renderable view-model so the UI pays
/// semantic validation once per batch push instead of rebuilding it in every view body.
public struct AcpPermissionDecisionPayload: Codable, Equatable, Sendable {
  public struct AgentContext: Codable, Equatable, Sendable {
    public let agentID: String
    public let agentName: String
    public let managedAgentID: String

    public init(agentID: String, agentName: String, managedAgentID: String) {
      self.agentID = agentID
      self.agentName = agentName
      self.managedAgentID = managedAgentID
    }
  }

  public struct RenderableBatch: Codable, Equatable, Sendable {
    public struct Request: Codable, Equatable, Sendable, Identifiable {
      public let id: String
      public let title: String
      public let detail: String
      public let breadcrumb: String

      public init(id: String, title: String, detail: String, breadcrumb: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.breadcrumb = breadcrumb
      }
    }

    public let batch: AcpPermissionBatch
    public let requests: [Request]

    public init(batch: AcpPermissionBatch, requests: [Request]) {
      self.batch = batch
      self.requests = requests
    }
  }

  public static let ruleID = "acp-permission"

  public let decisionID: String
  public let summary: String
  public let agent: AgentContext
  public let rawBatch: AcpPermissionBatch
  public let renderableBatch: RenderableBatch?
  public let renderError: RenderableError?

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder = JSONDecoder()

  public init(
    decisionID: String,
    summary: String,
    agent: AgentContext,
    rawBatch: AcpPermissionBatch,
    renderableBatch: RenderableBatch?,
    renderError: RenderableError?
  ) {
    self.decisionID = decisionID
    self.summary = summary
    self.agent = agent
    self.rawBatch = rawBatch
    self.renderableBatch = renderableBatch
    self.renderError = renderError
  }

  public static func decisionID(for batchID: String) -> String {
    "\(ruleID):\(batchID)"
  }

  public static func make(
    batch: AcpPermissionBatch,
    agentID: String,
    agentName: String
  ) -> Self {
    let decisionID = decisionID(for: batch.batchId)
    let agent = AgentContext(
      agentID: agentID,
      agentName: agentName,
      managedAgentID: batch.acpId
    )
    let renderable = validate(batch: batch)
    let summary =
      if renderable.error == nil {
        summary(agentName: agentName, requestCount: batch.requests.count)
      } else {
        "ACP permission request unavailable"
      }
    return Self(
      decisionID: decisionID,
      summary: summary,
      agent: agent,
      rawBatch: batch,
      renderableBatch: renderable.batch,
      renderError: renderable.error
    )
  }

  public static func decode(from decision: Decision) -> Self? {
    guard decision.ruleID == ruleID else {
      return nil
    }
    guard let data = decision.contextJSON.data(using: .utf8) else {
      return decodeFailure(for: decision, message: "Decision context is not valid UTF-8.")
    }
    guard let payload = try? decoder.decode(Self.self, from: data) else {
      return decodeFailure(
        for: decision,
        message: "Decision payload could not be decoded."
      )
    }
    return payload
  }

  public var requestCount: Int {
    rawBatch.requests.count
  }

  public var isRenderable: Bool {
    renderableBatch != nil
  }

  public var selectionSummary: String {
    "\(requestCount) of \(requestCount) selected"
  }

  public var defaultResolutionState: BatchResolutionState {
    BatchResolutionState.initial(
      batchID: rawBatch.batchId,
      requestIDs: renderableBatch?.requests.map(\.id) ?? []
    )
  }

  public var decisionDraft: DecisionDraft {
      DecisionDraft(
        id: decisionID,
        severity: .warn,
        ruleID: Self.ruleID,
        sessionID: rawBatch.sessionId,
        agentID: agent.agentID,
        taskID: nil,
        summary: summary,
      contextJSON: encodeJSONString(),
      suggestedActionsJSON: encodedSuggestedActionsJSON()
    )
  }

  public func selectionSummary(
    resolutionState: BatchResolutionState?
  ) -> String {
    let selectedCount = (resolutionState ?? defaultResolutionState).selectedRequestIDs.count
    return "\(selectedCount) of \(requestCount) selected"
  }

  public func encodeJSONString() -> String {
    guard
      let data = try? Self.encoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  public func encodedSuggestedActionsJSON() -> String {
    let actions = suggestedActions()
    guard
      let data = try? Self.encoder.encode(actions),
      let string = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return string
  }

  public func suggestedActions() -> [SuggestedAction] {
    guard renderableBatch != nil else {
      return []
    }

    if requestCount <= 1 {
      return [
        Self.suggestedAction(id: AcpPermissionDecisionActionID.approve, title: "Approve"),
        Self.suggestedAction(id: AcpPermissionDecisionActionID.deny, title: "Deny"),
      ]
    }

    return [
      Self.suggestedAction(id: AcpPermissionDecisionActionID.approveSelected, title: "Approve Selected"),
      Self.suggestedAction(id: AcpPermissionDecisionActionID.approveAll, title: "Approve All"),
      Self.suggestedAction(id: AcpPermissionDecisionActionID.denyAll, title: "Deny All"),
    ]
  }

  public func actionDecision(
    for actionID: String,
    resolutionState: BatchResolutionState?
  ) throws -> (decision: AcpPermissionDecision, outcome: DecisionOutcome) {
    switch actionID {
    case AcpPermissionDecisionActionID.approve, AcpPermissionDecisionActionID.approveAll:
      return (.approveAll, DecisionOutcome(chosenActionID: actionID, note: nil))
    case AcpPermissionDecisionActionID.approveSelected:
      let selectedIDs = (resolutionState ?? defaultResolutionState).selectedRequestIDs
      guard !selectedIDs.isEmpty else {
        throw AcpPermissionDecisionActionError.emptySelection
      }
      if selectedIDs.count == requestCount {
        return (.approveAll, DecisionOutcome(chosenActionID: actionID, note: nil))
      }
      return (.approveSome(selectedIDs), DecisionOutcome(chosenActionID: actionID, note: nil))
    case AcpPermissionDecisionActionID.deny, AcpPermissionDecisionActionID.denyAll:
      return (.denyAll, DecisionOutcome(chosenActionID: actionID, note: nil))
    default:
      throw AcpPermissionDecisionActionError.unknownAction(actionID)
    }
  }

  public func isActionDisabled(
    _ actionID: String,
    resolutionState: BatchResolutionState?
  ) -> Bool {
    if actionID == AcpPermissionDecisionActionID.approveSelected {
      return !(resolutionState ?? defaultResolutionState).hasSelection
    }
    return false
  }

  private static func suggestedAction(id: String, title: String) -> SuggestedAction {
    SuggestedAction(
      id: id,
      title: title,
      kind: .custom,
      payloadJSON: "{\"action\":\"\(id)\"}"
    )
  }

  private static func validate(
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

    var requests: [RenderableBatch.Request] = []
    requests.reserveCapacity(batch.requests.count)

    for request in batch.requests {
      guard !request.requestId.isEmpty else {
        return (nil, invalidBatchError("One ACP permission item is missing a request id."))
      }
      guard request.sessionId == batch.sessionId else {
        return (
          nil,
          invalidBatchError("ACP permission items did not match the selected session.")
        )
      }
      let title = toolCallLabel(request.toolCall, keys: ["kind", "name", "tool"]) ?? "Tool call"
      let detail = toolCallLabel(request.toolCall, keys: ["path", "command"])
        ?? compactJSON(request.toolCall)
      let breadcrumb = toolCallLabel(request.toolCall, keys: ["kind", "tool", "name"])
        ?? title
      requests.append(
        RenderableBatch.Request(
          id: request.requestId,
          title: title,
          detail: detail,
          breadcrumb: breadcrumb
        )
      )
    }

    return (RenderableBatch(batch: batch, requests: requests), nil)
  }

  private static func invalidBatchError(_ message: String) -> RenderableError {
    RenderableError(
      title: "ACP payload could not be rendered",
      message: message,
      recoverySuggestion: "Refresh the session or wait for a fresh ACP permission request."
    )
  }

  private static func decodeFailure(
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

  private static func summary(agentName: String, requestCount: Int) -> String {
    let suffix = requestCount == 1 ? "permission" : "permissions"
    return "\(agentName) requested \(requestCount) \(suffix)"
  }

  private static func toolCallLabel(_ value: JSONValue, keys: [String]) -> String? {
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

  private static func compactJSON(_ value: JSONValue) -> String {
    guard
      let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "Permission request"
    }
    return string
  }
}
