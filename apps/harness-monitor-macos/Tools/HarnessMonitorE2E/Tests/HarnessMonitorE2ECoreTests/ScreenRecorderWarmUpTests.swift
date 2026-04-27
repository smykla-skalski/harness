import XCTest

@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
@MainActor
final class ScreenRecorderWarmUpTests: XCTestCase {
  // The recorder helper runs `Runner.warmUpCoreGraphics()` synchronously on
  // the main thread before any ScreenCaptureKit call. The previous
  // implementation used `runAsync { await MainActor.run { … } }`, which
  // deadlocked: the main thread blocked on a DispatchSemaphore while the
  // spawned Task waited for the main actor to drain. The recorder hung
  // forever, leaving `screen-recording.log` empty and starving the swarm
  // fixture's `start.ready` ack.
  //
  // This test pins the contract that the warm-up returns promptly when
  // invoked from the main thread, exercising the same call path the
  // recorder takes after `prepareFilesystem`.
  func testWarmUpWindowServerReturnsPromptlyOnMainThread() {
    let start = Date()
    ScreenRecorder.warmUpWindowServer()
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(
      elapsed,
      1.0,
      "ScreenRecorder.warmUpWindowServer must return promptly on the main thread; got \(elapsed)s"
    )
  }
}
