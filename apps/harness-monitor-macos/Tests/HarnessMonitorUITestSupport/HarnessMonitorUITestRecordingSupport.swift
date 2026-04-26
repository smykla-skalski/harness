import AppKit
import XCTest

extension HarnessMonitorUITestCase {
  func armRecordingStartIfConfigured(
    context: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    guard let controlDirectory = Self.recordingControlDirectory() else {
      return true
    }

    let startRequest = controlDirectory.appendingPathComponent("start.request")
    let startAck = controlDirectory.appendingPathComponent("start.ready")
    let stopRequest = controlDirectory.appendingPathComponent("stop.request")
    let startPid = controlDirectory.appendingPathComponent("start.pid")

    recordDiagnosticsTrace(
      event: "recording.start.arm.begin",
      details: [
        "control_dir": controlDirectory.path,
        "start_request": startRequest.path,
        "start_ready": startAck.path,
        "stop_request": stopRequest.path,
        "start_pid": startPid.path,
      ]
    )
    do {
      try FileManager.default.createDirectory(
        at: controlDirectory,
        withIntermediateDirectories: true
      )
      for marker in [startRequest, startAck, stopRequest, startPid] {
        try? FileManager.default.removeItem(at: marker)
      }
      try Data().write(to: startRequest, options: .atomic)
      recordDiagnosticsTrace(
        event: "recording.start.arm.ready",
        details: [
          "control_dir": controlDirectory.path,
          "start_request": startRequest.path,
        ]
      )
    } catch {
      let suffix = context.isEmpty ? "" : "\n\(context)"
      recordDiagnosticsTrace(
        event: "recording.start.arm.failed",
        details: [
          "control_dir": controlDirectory.path,
          "error": String(describing: error),
        ]
      )
      XCTFail(
        "Failed to arm recording start markers in \(controlDirectory.path): \(error)\(suffix)",
        file: file,
        line: line
      )
      return false
    }

    return true
  }

  func provideRecordingPidIfConfigured(
    for app: XCUIApplication,
    context: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    guard let controlDirectory = Self.recordingControlDirectory() else {
      return true
    }
    guard let pid = Self.resolveLaunchedPid(forBundleIdentifier: Self.uiTestHostBundleIdentifier)
    else {
      let suffix = context.isEmpty ? "" : "\n\(context)"
      recordDiagnosticsTrace(
        event: "recording.pid.resolve.failed",
        details: [
          "control_dir": controlDirectory.path,
          "bundle_id": Self.uiTestHostBundleIdentifier,
        ]
      )
      XCTFail(
        "Could not resolve a running NSRunningApplication for "
          + "'\(Self.uiTestHostBundleIdentifier)' after launch; recorder needs the spawned PID."
          + suffix,
        file: file,
        line: line
      )
      return false
    }
    let target = controlDirectory.appendingPathComponent("start.pid")
    do {
      try FileManager.default.createDirectory(
        at: controlDirectory, withIntermediateDirectories: true)
      try Data("\(pid)\n".utf8).write(to: target, options: .atomic)
      recordDiagnosticsTrace(
        event: "recording.pid.published",
        details: [
          "control_dir": controlDirectory.path,
          "pid": String(pid),
          "start_pid": target.path,
        ]
      )
    } catch {
      let suffix = context.isEmpty ? "" : "\n\(context)"
      recordDiagnosticsTrace(
        event: "recording.pid.publish.failed",
        details: [
          "control_dir": controlDirectory.path,
          "pid": String(pid),
          "error": String(describing: error),
        ]
      )
      XCTFail(
        "Failed to publish recorder PID hint to \(target.path): \(error)\(suffix)",
        file: file,
        line: line
      )
      return false
    }
    return true
  }

  func waitForRecordingStartIfConfigured(
    context: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    guard let controlDirectory = Self.recordingControlDirectory() else {
      return true
    }

    let startAck = controlDirectory.appendingPathComponent("start.ready")
    recordDiagnosticsTrace(
      event: "recording.start.wait.begin",
      details: [
        "control_dir": controlDirectory.path,
        "start_ready": startAck.path,
      ]
    )
    if waitUntil(
      timeout: Self.uiTimeout,
      condition: {
        FileManager.default.fileExists(atPath: startAck.path)
      }
    ) {
      recordDiagnosticsTrace(
        event: "recording.start.wait.success",
        details: [
          "control_dir": controlDirectory.path,
          "start_ready": startAck.path,
        ]
      )
      return true
    }

    let suffix = context.isEmpty ? "" : "\n\(context)"
    recordDiagnosticsTrace(
      event: "recording.start.wait.timeout",
      details: [
        "control_dir": controlDirectory.path,
        "start_ready": startAck.path,
      ]
    )
    XCTFail(
      "Timed out waiting for recording start ack at \(startAck.path)\(suffix)",
      file: file,
      line: line
    )
    return false
  }

  static func signalRecordingStopIfConfigured() {
    guard let controlDirectory = recordingControlDirectory() else {
      return
    }

    let stopRequest = controlDirectory.appendingPathComponent("stop.request")
    do {
      try FileManager.default.createDirectory(
        at: controlDirectory,
        withIntermediateDirectories: true
      )
      try Data().write(to: stopRequest, options: .atomic)
    } catch {
      XCTFail("Failed to signal recording stop at \(stopRequest.path): \(error)")
    }
  }

  static func recordingControlDirectory() -> URL? {
    guard
      let rawValue = ProcessInfo.processInfo.environment[Self.recordingControlDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      rawValue.isEmpty == false
    else {
      return nil
    }
    return URL(fileURLWithPath: rawValue, isDirectory: true)
  }

  /// Most-recently-launched NSRunningApplication for the given bundle id, or nil
  /// when nothing matches. The recorder uses this to filter shareable windows
  /// down to the exact UI-testing host process the current XCTest run spawned.
  private static func resolveLaunchedPid(forBundleIdentifier bundleIdentifier: String) -> Int32? {
    Self.mostRecentRunningApplication(forBundleIdentifier: bundleIdentifier)?
      .processIdentifier
  }
}
