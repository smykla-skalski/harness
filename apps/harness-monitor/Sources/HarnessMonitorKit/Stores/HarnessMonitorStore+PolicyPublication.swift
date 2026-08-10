import Foundation

extension HarnessMonitorStore {
  func withSerializedTaskBoardPolicyPublication<Result>(
    _ operation: @MainActor () async -> Result
  ) async -> Result {
    await acquireTaskBoardPolicyPublicationLock()
    defer { releaseTaskBoardPolicyPublicationLock() }
    return await operation()
  }

  private func acquireTaskBoardPolicyPublicationLock() async {
    guard taskBoardRuntimeState.policyPublication.isLocked else {
      taskBoardRuntimeState.policyPublication.isLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      taskBoardRuntimeState.policyPublication.waiters.append(continuation)
    }
  }

  private func releaseTaskBoardPolicyPublicationLock() {
    guard !taskBoardRuntimeState.policyPublication.waiters.isEmpty else {
      taskBoardRuntimeState.policyPublication.isLocked = false
      return
    }
    taskBoardRuntimeState.policyPublication.waiters.removeFirst().resume()
  }
}
