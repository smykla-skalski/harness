import Foundation

extension ToastSlice {
  /// Daemon rejected a worker claim because the agent is currently parked in
  /// `AwaitingReview`. Corresponds to the `session_agent_busy_awaiting_review`
  /// failure surface.
  @discardableResult
  public func presentWorkerRefusal(
    agentID: String,
    taskID: String
  ) -> UUID {
    let message = "Agent \(agentID) is awaiting review. Task \(taskID) stays queued."
    return presentFailure(message)
  }

  /// Two or more agents tried to claim the same signal or review slot in the
  /// same round. Daemon emits a collision error; the UI surfaces it as a
  /// failure toast so reviewers can retry.
  @discardableResult
  public func presentSignalCollision(
    signalID: String,
    actorID: String
  ) -> UUID {
    let message =
      "Signal \(signalID) collided with a concurrent claim by \(actorID). Retry once the other actor settles."
    return presentFailure(message)
  }
}
