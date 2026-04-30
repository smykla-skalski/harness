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
  case notRenderable
  case unknownAction(String)

  public var errorDescription: String? {
    switch self {
    case .emptySelection:
      "Select at least one permission before approving."
    case .notRenderable:
      "ACP permission actions are unavailable because the request could not be rendered."
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
  public enum Kind: String, Codable, Equatable, Sendable {
    case acpPermission = "acp_permission"
  }

  private enum CodingKeys: String, CodingKey {
    case decisionKind
    case decisionID
    case summary
    case agent
    case rawBatch
    case renderableBatch
    case renderError
  }

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
  public static let decisionKind = Kind.acpPermission
  static let maximumRequestCount = 8
  static let unavailableSummary = "ACP permission request unavailable"

  public let decisionKind: Kind
  public let decisionID: String
  public let summary: String
  public let agent: AgentContext
  public let rawBatch: AcpPermissionBatch
  public let renderableBatch: RenderableBatch?
  public let renderError: RenderableError?

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder = JSONDecoder()

  public init(
    decisionKind: Kind = Self.decisionKind,
    decisionID: String,
    summary: String,
    agent: AgentContext,
    rawBatch: AcpPermissionBatch,
    renderableBatch: RenderableBatch?,
    renderError: RenderableError?
  ) {
    self.decisionKind = decisionKind
    self.decisionID = decisionID
    self.summary = summary
    self.agent = agent
    self.rawBatch = rawBatch
    self.renderableBatch = renderableBatch
    self.renderError = renderError
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    decisionKind = try container.decodeIfPresent(Kind.self, forKey: .decisionKind) ?? .acpPermission
    decisionID = try container.decode(String.self, forKey: .decisionID)
    summary = try container.decode(String.self, forKey: .summary)
    agent = try container.decode(AgentContext.self, forKey: .agent)
    rawBatch = try container.decode(AcpPermissionBatch.self, forKey: .rawBatch)
    renderableBatch = try container.decodeIfPresent(RenderableBatch.self, forKey: .renderableBatch)
    renderError = try container.decodeIfPresent(RenderableError.self, forKey: .renderError)
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
        unavailableSummary
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
    guard payload.decisionKind == decisionKind else {
      return decodeFailure(
        for: decision,
        message: "Persisted ACP payload decision kind did not match the ACP contract."
      )
    }
    return revalidatedDecodedPayload(payload, decision: decision)
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
      Self.suggestedAction(
        id: AcpPermissionDecisionActionID.approveSelected, title: "Approve Selected"),
      Self.suggestedAction(id: AcpPermissionDecisionActionID.approveAll, title: "Approve All"),
      Self.suggestedAction(id: AcpPermissionDecisionActionID.denyAll, title: "Deny All"),
    ]
  }

  public func actionDecision(
    for actionID: String,
    resolutionState: BatchResolutionState?
  ) throws -> (decision: AcpPermissionDecision, outcome: DecisionOutcome) {
    guard isRenderable else {
      throw AcpPermissionDecisionActionError.notRenderable
    }

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
    guard isRenderable else {
      return true
    }
    if actionID == AcpPermissionDecisionActionID.approveSelected {
      return !(resolutionState ?? defaultResolutionState).hasSelection
    }
    return false
  }

}
