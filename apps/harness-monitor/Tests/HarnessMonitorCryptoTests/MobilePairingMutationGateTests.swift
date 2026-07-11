@testable import HarnessMonitorCrypto
import XCTest

final class MobilePairingMutationGateTests: XCTestCase {
  func testConcurrentMutationsRunOneAtATime() async throws {
    let gate = MobilePairingMutationGate()
    let firstStarted = expectation(description: "first mutation started")
    let releaseFirst = MutationReleaseGate()

    let first = Task {
      try await gate.perform {
        firstStarted.fulfill()
        await releaseFirst.wait()
      }
    }
    await fulfillment(of: [firstStarted], timeout: 1)

    let second = Task {
      try await gate.perform {}
    }
    await gate.waitUntilQueuedOperations(atLeast: 1)

    await releaseFirst.release()
    try await first.value
    try await second.value
  }

  func testReentrantMutationThrowsInsteadOfDeadlocking() async throws {
    let gate = MobilePairingMutationGate()

    do {
      try await gate.perform {
        try await gate.perform {}
      }
      XCTFail("nested mutation should fail")
    } catch let error as MobilePairingMutationGateError {
      XCTAssertEqual(error, .reentrantMutation)
    }
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
