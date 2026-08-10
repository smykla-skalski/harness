import Foundation

extension HarnessMonitorStore {
  func withSerializedTaskBoardPolicyPublication<Result>(
    cancellationResult: @autoclosure () -> Result,
    _ operation: @MainActor () async -> Result
  ) async -> Result {
    let acquired = await acquireTaskBoardPolicyPublicationLock()
    guard acquired, !Task.isCancelled else {
      if acquired {
        releaseTaskBoardPolicyPublicationLock()
      }
      return cancellationResult()
    }
    defer { releaseTaskBoardPolicyPublicationLock() }
    return await operation()
  }

  private func acquireTaskBoardPolicyPublicationLock() async -> Bool {
    guard !Task.isCancelled else { return false }
    guard taskBoardRuntimeState.policyPublication.isLocked else {
      taskBoardRuntimeState.policyPublication.isLocked = true
      return true
    }
    let waiterID = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        taskBoardRuntimeState.policyPublication.waiters.append(
          TaskBoardPolicyPublicationWaiter(
            id: waiterID,
            continuation: continuation
          )
        )
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelTaskBoardPolicyPublicationWaiter(id: waiterID)
      }
    }
  }

  private func releaseTaskBoardPolicyPublicationLock() {
    guard !taskBoardRuntimeState.policyPublication.waiters.isEmpty else {
      taskBoardRuntimeState.policyPublication.isLocked = false
      return
    }
    taskBoardRuntimeState.policyPublication.waiters.removeFirst().continuation.resume(
      returning: true
    )
  }

  private func cancelTaskBoardPolicyPublicationWaiter(id: UUID) {
    guard
      let index = taskBoardRuntimeState.policyPublication.waiters.firstIndex(where: {
        $0.id == id
      })
    else { return }
    let waiter = taskBoardRuntimeState.policyPublication.waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}
