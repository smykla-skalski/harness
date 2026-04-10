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
    guard guardSessionActionsAvailable() else { return false }
    guard let client, let sessionID = selectedSessionID else { return false }
    guard let actor = actionActor(for: actor) else { return false }
    return await mutateSelectedSession(
      actionName: "Send signal",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.sendSignal(
          sessionID: sessionID,
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
    guard guardSessionActionsAvailable() else { return false }
    guard let client, let sessionID = selectedSessionID else { return false }
    guard let actor = actionActor(for: actor) else { return false }
    return await mutateSelectedSession(
      actionName: "Cancel signal",
      using: client,
      sessionID: sessionID,
      mutation: {
        try await client.cancelSignal(
          sessionID: sessionID,
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
