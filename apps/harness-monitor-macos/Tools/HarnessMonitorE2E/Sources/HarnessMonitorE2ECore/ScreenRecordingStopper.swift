import Darwin
import Foundation

public protocol ScreenRecordingProcessRuntime {
  func now() -> Date
  func sleep(seconds: TimeInterval)
  func isAlive(pid: Int32) -> Bool
  func send(signal: Int32, to pid: Int32)
}

public struct SystemScreenRecordingProcessRuntime: ScreenRecordingProcessRuntime {
  public init() {}

  public func now() -> Date {
    Date.now
  }

  public func sleep(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }

  public func isAlive(pid: Int32) -> Bool {
    kill(pid, 0) == 0
  }

  public func send(signal: Int32, to pid: Int32) {
    _ = kill(pid, signal)
  }
}

public enum ScreenRecordingStopper {
  public static func stop(
    manifest: ScreenRecordingManifest,
    runtime: some ScreenRecordingProcessRuntime = SystemScreenRecordingProcessRuntime(),
    gracefulTimeout: TimeInterval = 10,
    termTimeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.2
  ) {
    guard manifest.processID > 0 else { return }

    runtime.send(signal: SIGINT, to: manifest.processID)
    if waitForExit(
      pid: manifest.processID,
      timeout: gracefulTimeout,
      pollInterval: pollInterval,
      runtime: runtime
    ) {
      return
    }

    runtime.send(signal: SIGTERM, to: manifest.processID)
    if waitForExit(
      pid: manifest.processID,
      timeout: termTimeout,
      pollInterval: pollInterval,
      runtime: runtime
    ) {
      return
    }

    runtime.send(signal: SIGKILL, to: manifest.processID)
  }

  private static func waitForExit(
    pid: Int32,
    timeout: TimeInterval,
    pollInterval: TimeInterval,
    runtime: some ScreenRecordingProcessRuntime
  ) -> Bool {
    let deadline = runtime.now().addingTimeInterval(timeout)
    while runtime.now() < deadline {
      if !runtime.isAlive(pid: pid) {
        return true
      }
      runtime.sleep(seconds: pollInterval)
    }
    return !runtime.isAlive(pid: pid)
  }
}
