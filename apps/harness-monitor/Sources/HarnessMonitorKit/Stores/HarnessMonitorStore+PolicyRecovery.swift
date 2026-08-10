import Foundation

extension HarnessMonitorStore {
  private static let policyRecoveryMaxRetrySeconds = 30

  func handleTaskBoardPolicyRecoveryFailure(access: TaskBoardClientAccess) -> Bool {
    guard taskBoardPolicyRuntimeRecoveryPending, taskBoardAccessIsCurrent(access) else {
      return false
    }
    scheduleTaskBoardPolicyRecoveryRetry(access: access)
    return false
  }

  func completeTaskBoardPolicyRecovery() async {
    await supervisorStack?.service.setPolicyRecoverySuppressed(false)
    taskBoardPolicyRuntimeRecoveryPending = false
    resetTaskBoardPolicyRecoveryRetry()
  }

  func resetTaskBoardPolicyRecoveryRetry() {
    cacheWriteSync.taskBoardPolicyRecoveryGeneration &+= 1
    cacheWriteSync.taskBoardPolicyRecoveryTask?.cancel()
    cacheWriteSync.taskBoardPolicyRecoveryTask = nil
    cacheWriteSync.taskBoardPolicyRecoveryAttempt = 0
  }

  private func scheduleTaskBoardPolicyRecoveryRetry(access: TaskBoardClientAccess) {
    guard cacheWriteSync.taskBoardPolicyRecoveryTask == nil else { return }
    let attempt = cacheWriteSync.taskBoardPolicyRecoveryAttempt
    cacheWriteSync.taskBoardPolicyRecoveryAttempt &+= 1
    cacheWriteSync.taskBoardPolicyRecoveryGeneration &+= 1
    let generation = cacheWriteSync.taskBoardPolicyRecoveryGeneration
    let delay =
      cacheWriteSync.policyRecoveryRetryOverride
      ?? Self.taskBoardPolicyRecoveryRetryDelay(attempt: attempt)
    cacheWriteSync.taskBoardPolicyRecoveryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self,
        self.cacheWriteSync.taskBoardPolicyRecoveryGeneration == generation
      else { return }
      self.cacheWriteSync.taskBoardPolicyRecoveryTask = nil
      guard
        self.taskBoardPolicyRuntimeRecoveryPending,
        self.taskBoardAccessIsCurrent(access)
      else { return }
      await self.refreshPolicyPipeline()
    }
  }

  private static func taskBoardPolicyRecoveryRetryDelay(attempt: Int) -> Duration {
    let exponent = min(max(attempt, 0), 5)
    return .seconds(min(policyRecoveryMaxRetrySeconds, 1 << exponent))
  }
}
