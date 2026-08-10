import Foundation

@testable import HarnessMonitorKit

actor RecordingTaskBoardOrchestratorSettingsMutationGate {
  private struct ArrivalWaiter {
    let id: UUID
    let count: Int
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var remainingBlocks = 0
  private var blockedArrivalCount = 0
  private var blockedContinuations: [CheckedContinuation<Void, Never>] = []
  private var arrivalWaiters: [ArrivalWaiter] = []

  func blockNext(_ count: Int) {
    precondition(count >= 0)
    precondition(blockedContinuations.isEmpty)
    remainingBlocks = count
    blockedArrivalCount = 0
  }

  func suspendIfConfigured() async {
    guard remainingBlocks > 0 else { return }
    remainingBlocks -= 1
    blockedArrivalCount += 1
    resumeSatisfiedArrivalWaiters()
    await withCheckedContinuation { continuation in
      blockedContinuations.append(continuation)
    }
  }

  func waitForBlockedArrivalCount(
    _ count: Int,
    timeout: Duration = .seconds(5)
  ) async -> Bool {
    guard blockedArrivalCount < count else { return true }
    let id = UUID()
    return await withCheckedContinuation { continuation in
      arrivalWaiters.append(ArrivalWaiter(id: id, count: count, continuation: continuation))
      Task { [weak self] in
        try? await Task.sleep(for: timeout)
        await self?.expireArrivalWaiter(id: id)
      }
    }
  }

  func releaseNext() {
    precondition(!blockedContinuations.isEmpty)
    blockedContinuations.removeFirst().resume()
  }

  private func resumeSatisfiedArrivalWaiters() {
    var pending: [ArrivalWaiter] = []
    for waiter in arrivalWaiters {
      if blockedArrivalCount >= waiter.count {
        waiter.continuation.resume(returning: true)
      } else {
        pending.append(waiter)
      }
    }
    arrivalWaiters = pending
  }

  private func expireArrivalWaiter(id: UUID) {
    guard let index = arrivalWaiters.firstIndex(where: { $0.id == id }) else { return }
    arrivalWaiters.remove(at: index).continuation.resume(returning: false)
  }
}

actor RecordingTaskBoardOperationResult<Value: Sendable> {
  private(set) var value: Value?

  func record(_ value: Value) {
    self.value = value
  }
}

extension RecordingHarnessClient {
  func configureTaskBoardOrchestratorSettingsResponse(
    _ settings: TaskBoardOrchestratorSettings?
  ) {
    lock.withLock {
      taskBoardOrchestratorSettingsResponse = settings
    }
  }

  func blockNextTaskBoardOrchestratorSettingsMutations(_ count: Int = 1) async {
    await orchestratorSettingsMutationGate.blockNext(count)
  }

  @discardableResult
  func waitForBlockedTaskBoardOrchestratorSettingsMutations(_ count: Int = 1) async -> Bool {
    await orchestratorSettingsMutationGate.waitForBlockedArrivalCount(count)
  }

  func releaseNextTaskBoardOrchestratorSettingsMutation() async {
    await orchestratorSettingsMutationGate.releaseNext()
  }
}
