import XCTest

final class TestClockTests: XCTestCase {
  func test_sleepThrowsCancellationErrorWhenTaskIsCancelled() async throws {
    let clock = TestClock()
    let cancelled = expectation(description: "sleep cancelled")

    let sleeper = Task {
      do {
        try await clock.sleep(for: .seconds(5))
        XCTFail("Cancelled sleep should not complete successfully")
      } catch is CancellationError {
        cancelled.fulfill()
      } catch {
        XCTFail("Expected CancellationError, got \(error)")
      }
    }

    sleeper.cancel()

    await fulfillment(of: [cancelled], timeout: 1)
  }
}
