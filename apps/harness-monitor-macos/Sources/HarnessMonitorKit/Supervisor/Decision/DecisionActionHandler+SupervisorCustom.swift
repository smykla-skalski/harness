import Foundation

@MainActor
extension StoreDecisionActionHandler {
  static func handleSupervisorCustomAction(
    _ action: SuggestedAction,
    store: HarnessMonitorStore
  ) async throws {
    let payload = try JSONDecoder().decode(
      SupervisorCustomActionPayload.self,
      from: Data(action.payloadJSON.utf8)
    )
    switch payload.mode {
    case "restartDaemon":
      await store.stopDaemon()
      await store.startDaemon()
    case "openDaemonLogs":
      guard store.openDaemonLog() else {
        throw StoreDecisionActionError.daemonLogUnavailable
      }
    case "closeSession":
      guard let sessionID = payload.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
        !sessionID.isEmpty
      else {
        throw StoreDecisionActionError.missingTargetMetadata("sessionID")
      }
      let removed = await store.removeSession(sessionID: sessionID, actorID: "harness-supervisor")
      guard removed else {
        throw StoreDecisionActionError.sessionActionFailed(sessionID)
      }
    case "investigate", "investigateManually":
      return
    default:
      throw StoreDecisionActionError.unsupportedCustomAction(payload.mode)
    }
  }
}
