import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func sendSignal(
    agentID: String,
    command: String,
    message: String,
    actionHint: String?,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Send signal"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return false }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.sendSignal(sessionID: action.sessionID, agentID: agentID).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.sendSignal(
          sessionID: action.sessionID,
          request: SignalSendRequest(
            actor: actor,
            agentId: agentID,
            command: command,
            message: message,
            actionHint: actionHint
          )
        )
      }
    )
  }

  @discardableResult
  public func cancelSignal(
    signalID: String,
    agentID: String,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Cancel signal"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    guard let actor = actionActor(for: actor, actionName: actionName) else { return false }
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.cancelSignal(
        sessionID: action.sessionID,
        signalID: signalID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.cancelSignal(
          sessionID: action.sessionID,
          request: SignalCancelRequest(
            actor: actor,
            agentId: agentID,
            signalId: signalID
          )
        )
      }
    )
  }

  @discardableResult
  public func resendSignal(
    _ record: SessionSignalRecord,
    actor: String = "harness-app"
  ) async -> Bool {
    await sendSignal(
      agentID: record.agentId,
      command: record.signal.command,
      message: record.signal.payload.message,
      actionHint: record.signal.payload.actionHint,
      actor: actor
    )
  }
}
