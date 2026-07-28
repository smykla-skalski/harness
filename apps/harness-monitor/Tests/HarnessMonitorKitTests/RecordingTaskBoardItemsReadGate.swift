import Foundation

@testable import HarnessMonitorKit

actor RecordingTaskBoardItemsReadGate {
  private var shouldBlockNextRead = false
  private var didBlockRead = false
  private var blockedReadContinuation: CheckedContinuation<Void, Never>?
  private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

  func blockNextRead() {
    precondition(blockedReadContinuation == nil)
    shouldBlockNextRead = true
    didBlockRead = false
  }

  func suspendIfConfigured() async {
    guard shouldBlockNextRead else { return }
    shouldBlockNextRead = false
    didBlockRead = true
    let arrivals = arrivalContinuations
    arrivalContinuations.removeAll()
    arrivals.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      blockedReadContinuation = continuation
    }
  }

  func waitUntilBlocked() async {
    guard !didBlockRead else { return }
    await withCheckedContinuation { continuation in
      arrivalContinuations.append(continuation)
    }
  }

  func release() {
    precondition(blockedReadContinuation != nil)
    blockedReadContinuation?.resume()
    blockedReadContinuation = nil
  }
}

extension RecordingHarnessClient {
  func blockNextTaskBoardItemsRead() async {
    await taskBoardItemsReadGate.blockNextRead()
  }

  func waitUntilTaskBoardItemsReadIsBlocked() async {
    await taskBoardItemsReadGate.waitUntilBlocked()
  }

  func releaseTaskBoardItemsRead() async {
    await taskBoardItemsReadGate.release()
  }
}
