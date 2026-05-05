import Foundation

struct CodexApprovalSuggestedActionPayload: Decodable {
  let mode: String
  let agentID: String
  let approvalID: String
  let decision: String
}

struct TaskActionPayload: Decodable {
  let sessionID: String?
  let taskID: String
  let agentID: String
}

struct NudgeActionPayload: Decodable {
  let agentID: String?
  let input: String?
}

struct SupervisorCustomActionPayload: Decodable {
  let mode: String
  let sessionID: String?
}

struct DecisionContextEnvelope {
  let agentID: String?

  init?(_ json: String) {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      return nil
    }
    agentID = dictionary["agentID"] as? String
  }
}

struct TaskLocation {
  let sessionID: String
  let assignedAgentID: String?
}

struct DecisionActionSnapshot: Sendable {
  let id: String
  let ruleID: String
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let contextJSON: String
  let suggestedActionsJSON: String

  init(decision: Decision) {
    id = decision.id
    ruleID = decision.ruleID
    sessionID = decision.sessionID
    agentID = decision.agentID
    taskID = decision.taskID
    contextJSON = decision.contextJSON
    suggestedActionsJSON = decision.suggestedActionsJSON
  }
}

enum StoreDecisionActionError: LocalizedError {
  case missingDecision(String)
  case missingClient
  case missingCodexRun(String)
  case invalidCodexPayload
  case missingTargetMetadata(String)
  case daemonUnavailable
  case notificationUnavailable
  case notificationDeliveryFailed
  case daemonLogUnavailable
  case sessionActionFailed(String)
  case daemonRejected(any Error)
  case unsupportedCustomAction(String)

  var errorDescription: String? {
    switch self {
    case .missingDecision(let decisionID):
      "Decision \(decisionID) is no longer available."
    case .missingClient:
      "Monitor is not connected to the daemon."
    case .missingCodexRun(let approvalID):
      "Could not locate the Codex run for approval \(approvalID)."
    case .invalidCodexPayload:
      "The Codex approval action payload is invalid."
    case .missingTargetMetadata(let field):
      "Cannot run action: missing target metadata (\(field))."
    case .daemonUnavailable:
      "Cannot run action: daemon unavailable."
    case .notificationUnavailable:
      "Cannot run action: notification controller unavailable."
    case .notificationDeliveryFailed:
      "Cannot run action: notification delivery failed."
    case .daemonLogUnavailable:
      "Cannot run action: daemon log is unavailable."
    case .sessionActionFailed(let sessionID):
      "Cannot run action: session action failed for \(sessionID)."
    case .daemonRejected(let error):
      "Action rejected by daemon: \(error.localizedDescription)"
    case .unsupportedCustomAction(let mode):
      "Cannot run action: unsupported custom action \(mode)."
    }
  }
}

enum SupervisorManagedAgentNudgeDispatcher {
  private static let supervisorActor = "harness-supervisor"
  private static let signalCommand = "request_action"

  static func dispatch(
    agentID: String,
    input: String,
    client: any HarnessMonitorClientProtocol
  ) async throws {
    let snapshot = try await client.managedAgent(agentID: agentID)
    if snapshot.terminal != nil {
      _ = try await client.sendManagedAgentInput(
        agentID: agentID,
        request: AgentTuiInputRequest(input: .text(input))
      )
      return
    }

    // ACP/Codex nudges must use session signals; managed_agent.input is terminal-only.
    _ = try await client.sendSignal(
      sessionID: snapshot.sessionId,
      request: SignalSendRequest(
        actor: supervisorActor,
        agentId: agentID,
        command: signalCommand,
        message: input,
        actionHint: nil
      )
    )
  }
}
