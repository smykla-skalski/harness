import Foundation

@available(macOS 15.0, *)
enum ScreenRecorderStartGate {
  static func awaitStartThenResolve<T>(
    waitForStartRequest: () -> Bool,
    resolveCapture: () throws -> T?,
    timeout: TimeInterval = 15,
    pollInterval: TimeInterval = 0.2,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) throws -> T? {
    guard waitForStartRequest() else {
      return nil
    }

    let deadline = now().addingTimeInterval(timeout)
    while true {
      if let capture = try resolveCapture() {
        return capture
      }
      if now() >= deadline {
        throw ScreenRecorder.Failure.monitorWindowStartTimedOut(timeout)
      }
      sleep(pollInterval)
    }
  }
}
