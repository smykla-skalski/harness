import HarnessMonitorCrypto
import XCTest

final class MobilePairingMutationGateTests: XCTestCase {
  func testConcurrentMutationsRunOneAtATime() async throws {
    let gate = MobilePairingMutationGate()
    let firstStarted = expectation(description: "first mutation started")
    let secondStarted = expectation(description: "second mutation started")
    secondStarted.isInverted = true
    let releaseFirst = MutationReleaseGate()

    let first = Task {
      try await gate.perform {
        firstStarted.fulfill()
        await releaseFirst.wait()
      }
    }
    await fulfillment(of: [firstStarted], timeout: 1)

    let second = Task {
      try await gate.perform {
        secondStarted.fulfill()
      }
    }
    await fulfillment(of: [secondStarted], timeout: 0.1)

    await releaseFirst.release()
    try await first.value
    try await second.value
  }
}

private actor MutationReleaseGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    guard !released else {
      return
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
