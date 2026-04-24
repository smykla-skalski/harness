import Foundation

extension HarnessMonitorStore {
  func presentSelectedSessionMutationFailure(
    _ error: any Error,
    actionID: String
  ) {
    guard presentReviewSpecificFailure(error, actionID: actionID) == false else {
      return
    }
    presentFailureFeedback(error.localizedDescription)
  }

  private func presentReviewSpecificFailure(
    _ error: any Error,
    actionID: String
  ) -> Bool {
    let message = error.localizedDescription.lowercased()
    if message.contains("session_agent_busy_awaiting_review") {
      toast.presentWorkerRefusal(
        agentID: resolvedActionActor() ?? "unknown-agent",
        taskID: trailingActionResourceID(from: actionID) ?? "unknown-task"
      )
      return true
    }
    if message.contains("runtime_already_reviewing")
      || message.contains("signal_collision")
      || (message.contains("signal") && message.contains("collid"))
    {
      toast.presentSignalCollision(
        signalID: trailingActionResourceID(from: actionID) ?? "review-slot",
        actorID: resolvedActionActor() ?? "unknown-actor"
      )
      return true
    }
    return false
  }

  private func trailingActionResourceID(from actionID: String) -> String? {
    actionID.split(separator: "/").last.map(String.init)
  }
}
