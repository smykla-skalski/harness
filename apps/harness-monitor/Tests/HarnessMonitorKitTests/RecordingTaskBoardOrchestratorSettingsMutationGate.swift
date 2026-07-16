import Foundation

@testable import HarnessMonitorKit

actor RecordingTaskBoardOrchestratorSettingsMutationGate {
  private struct ArrivalWaiter {
    let count: Int
    let continuation: CheckedContinuation<Void, Never>
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

  func waitForBlockedArrivalCount(_ count: Int) async {
    guard blockedArrivalCount < count else { return }
    await withCheckedContinuation { continuation in
      arrivalWaiters.append(ArrivalWaiter(count: count, continuation: continuation))
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
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    arrivalWaiters = pending
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

  func waitForBlockedTaskBoardOrchestratorSettingsMutations(_ count: Int = 1) async {
    await orchestratorSettingsMutationGate.waitForBlockedArrivalCount(count)
  }

  func releaseNextTaskBoardOrchestratorSettingsMutation() async {
    await orchestratorSettingsMutationGate.releaseNext()
  }
}
