import HarnessMonitorCore
import XCTest

final class MobileAsyncTimeoutTests: XCTestCase {
  func testTimeoutReturnsWhenOperationNeverCompletes() async throws {
    let start = ContinuousClock.now

    do {
      _ = try await MobileAsyncTimeout.run(
        timeout: .milliseconds(20),
        timeoutError: { MobileMirrorRefreshTimeout() }
      ) {
        await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
      }
      XCTFail("Expected timeout")
    } catch let error as MobileMirrorRefreshTimeout {
      XCTAssertEqual(error, MobileMirrorRefreshTimeout())
    }

    let elapsed = start.duration(to: .now)
    XCTAssertLessThan(elapsed, .seconds(1))
  }

  func testReadableDescriptionSurfacesLocalizedTimeoutMessage() {
    let reason = mobileMirrorReadableErrorDescription(MobileMirrorRefreshTimeout())
    XCTAssertEqual(
      reason,
      "Timed out fetching the encrypted mirror. Showing the last cached state."
    )
    XCTAssertFalse(reason.contains("MobileMirrorRefreshTimeout"))
  }
}
