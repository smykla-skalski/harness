import Foundation
import HarnessMonitorCloudMirror
import XCTest

final class MobileCloudMirrorZoneEnsurerTests: XCTestCase {
  func testEnsureRunsOperationOnlyOnceAcrossSequentialCalls() async throws {
    let counter = ZoneEnsureCounter()
    let ensurer = MobileCloudMirrorZoneEnsurer { try await counter.run() }

    try await ensurer.ensureIfNeeded()
    try await ensurer.ensureIfNeeded()
    try await ensurer.ensureIfNeeded()

    let runCount = await counter.runCount
    XCTAssertEqual(runCount, 1)
  }

  func testConcurrentEnsureRunsOperationOnce() async throws {
    let counter = ZoneEnsureCounter()
    let ensurer = MobileCloudMirrorZoneEnsurer { try await counter.run() }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { try await ensurer.ensureIfNeeded() }
      }
      try await group.waitForAll()
    }

    let runCount = await counter.runCount
    XCTAssertEqual(runCount, 1)
  }

  func testInvalidateReArmsEnsure() async throws {
    let counter = ZoneEnsureCounter()
    let ensurer = MobileCloudMirrorZoneEnsurer { try await counter.run() }

    try await ensurer.ensureIfNeeded()
    await ensurer.invalidate()
    try await ensurer.ensureIfNeeded()

    let runCount = await counter.runCount
    XCTAssertEqual(runCount, 2)
  }

  func testFailedEnsureAllowsRetry() async throws {
    let counter = ZoneEnsureCounter()
    await counter.failNextRuns(1)
    let ensurer = MobileCloudMirrorZoneEnsurer { try await counter.run() }

    do {
      try await ensurer.ensureIfNeeded()
      XCTFail("expected the first ensure to throw")
    } catch {
      // expected: the underlying operation failed once
    }
    try await ensurer.ensureIfNeeded()

    let runCount = await counter.runCount
    XCTAssertEqual(runCount, 2)
  }
}

private actor ZoneEnsureCounter {
  private(set) var runCount = 0
  private var remainingFailures = 0

  func failNextRuns(_ count: Int) {
    remainingFailures = count
  }

  func run() throws {
    runCount += 1
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw ZoneEnsureCounterError.simulated
    }
  }
}

private enum ZoneEnsureCounterError: Error {
  case simulated
}
