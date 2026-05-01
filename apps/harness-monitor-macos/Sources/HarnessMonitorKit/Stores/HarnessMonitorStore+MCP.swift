import Foundation

struct MCPStatusFeedbackState {
  var activeFailureReason: String?
  var shouldPresentRecoverySuccess = false

  mutating func recordDegraded(reason: String?) -> Bool {
    let shouldPresentFailure = !shouldPresentRecoverySuccess || activeFailureReason != reason
    shouldPresentRecoverySuccess = true
    activeFailureReason = reason
    return shouldPresentFailure
  }

  mutating func reset() {
    activeFailureReason = nil
    shouldPresentRecoverySuccess = false
  }
}

extension HarnessMonitorStore {
  public func updateMCPStatus(_ nextStatus: HarnessMonitorMCPStatusSnapshot) {
    let previousStatus = mcpStatus
    guard previousStatus != nextStatus else {
      return
    }

    mcpStatus = nextStatus
    presentMCPStatusFeedbackIfNeeded(nextStatus)
  }

  public func updateMCPStatus(
    runtimeState: HarnessMonitorMCPRuntimeState,
    recoveryStatus: HarnessMonitorMCPRecoveryStatus?
  ) {
    updateMCPStatus(
      HarnessMonitorMCPStatusSnapshot(
        runtimeState: runtimeState,
        recoveryStatus: recoveryStatus
      )
    )
  }

  private func presentMCPStatusFeedbackIfNeeded(
    _ nextStatus: HarnessMonitorMCPStatusSnapshot
  ) {
    switch nextStatus.runtimeState {
    case .degraded:
      let shouldPresentFailure = mcpFeedbackState.recordDegraded(
        reason: nextStatus.failureReason
      )
      guard shouldPresentFailure,
        let failureMessage = nextStatus.failureFeedbackMessage
      else {
        return
      }
      presentFailureFeedback(failureMessage)
    case .healthy:
      if mcpFeedbackState.shouldPresentRecoverySuccess {
        presentSuccessFeedback("MCP registry host recovered and is ready.")
      }
      mcpFeedbackState.reset()
    case .disabled:
      mcpFeedbackState.reset()
    case .starting:
      return
    }
  }
}
