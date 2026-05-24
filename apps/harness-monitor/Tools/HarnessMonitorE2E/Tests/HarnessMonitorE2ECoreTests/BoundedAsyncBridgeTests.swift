import XCTest

@testable import HarnessMonitorE2ECore

final class BoundedAsyncBridgeTests: XCTestCase {
  func testBoundedRunReturnsCompletedWhenOperationFinishesEarly() throws {
    let result: BoundedAsyncResult<Int> = try runAsyncBounded(timeout: 1.0) {
      try await Task.sleep(nanoseconds: 5_000_000)
      return 42
    }
    switch result {
    case .completed(let value):
      XCTAssertEqual(value, 42)
    case .timedOut:
      XCTFail("Expected completed, got timedOut")
    }
  }

  func testBoundedRunReturnsTimedOutWhenOperationStalls() throws {
    let started = Date()
    let result: BoundedAsyncResult<Int> = try runAsyncBounded(timeout: 0.2) {
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return 1
    }
    let elapsed = Date().timeIntervalSince(started)
    switch result {
    case .completed:
      XCTFail("Expected timedOut, got completed")
    case .timedOut:
      XCTAssertLessThan(elapsed, 1.0, "Bounded run should return shortly after deadline")
    }
  }

  func testBoundedRunRethrowsOperationFailure() {
    struct Boom: Error {}
    do {
      let _: BoundedAsyncResult<Int> = try runAsyncBounded(timeout: 1.0) {
        throw Boom()
      }
      XCTFail("Expected throw")
    } catch is Boom {
      // expected
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}
