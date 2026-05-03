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
    case "investigate", "investigateManually":
      return
    default:
      throw StoreDecisionActionError.unsupportedCustomAction(payload.mode)
    }
  }
}
