import AppKit
import Foundation
import XCTest

private final class HarnessMonitorUITestFailureTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var failedTests: Set<String> = []

  func markFailed(_ testName: String) {
    lock.lock()
    failedTests.insert(testName)
    lock.unlock()
  }

  func takeFailure(for testName: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return failedTests.remove(testName) != nil
  }
}

@MainActor
class HarnessMonitorUITestCase: XCTestCase {
  nonisolated static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"
  nonisolated static let daemonDataHomeKey = "HARNESS_DAEMON_DATA_HOME"
  nonisolated static let artifactsDirectoryKey = "HARNESS_MONITOR_UI_TEST_ARTIFACTS_DIR"
  nonisolated static let recordingControlDirectoryKey =
    "HARNESS_MONITOR_UI_TEST_RECORDING_CONTROL_DIR"
  nonisolated static let uiTestHostBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  nonisolated static let uiTimeout: TimeInterval = 10
  nonisolated static let actionTimeout: TimeInterval = 2
  nonisolated static let fastActionTimeout: TimeInterval = 0.4
  nonisolated static let fastPollInterval: TimeInterval = 0.02

  /// Subclasses override to keep the launched UI-test host alive across test methods
  /// in the same class. Eliminates the terminate + relaunch dead wait between cases.
  /// Only safe when every test launches the host with identical mode/environment.
  nonisolated class var reuseLaunchedApp: Bool { false }
  nonisolated private static let failureTracker = HarnessMonitorUITestFailureTracker()

  static var cachedLaunchedApp: XCUIApplication?
  var launchedAppForTeardown: XCUIApplication?

  override func setUpWithError() throws {
    continueAfterFailure = false
    let testName = name
    let artifactsKey = Self.artifactsDirectoryKey
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.setup",
      testName: testName,
      artifactsDirectoryKey: artifactsKey
    )
    addTeardownBlock { @MainActor in
      appendDiagnosticsTrace(
        component: "ui-test",
        event: "test.teardown.begin",
        testName: testName,
        artifactsDirectoryKey: artifactsKey
      )
      if Self.failureTracker.takeFailure(for: testName) {
        let snapshotName = "failure-final-\(UUID().uuidString.lowercased())"
        let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
        appendDiagnosticsTrace(
          component: "ui-test",
          event: "test.failure.snapshot",
          testName: testName,
          details: ["snapshot": snapshotName],
          artifactsDirectoryKey: artifactsKey
        )
        recordStandaloneDiagnosticsSnapshot(
          in: app,
          named: snapshotName,
          artifactsDirectoryKey: artifactsKey
        )
      }
      if !Self.reuseLaunchedApp, let launchedApp = self.launchedAppForTeardown {
        appendDiagnosticsTrace(
          component: "ui-test",
          event: "test.teardown.terminate-app",
          testName: testName,
          artifactsDirectoryKey: artifactsKey
        )
        Self.terminateAndWait(launchedApp)
        self.launchedAppForTeardown = nil
      }
      appendDiagnosticsTrace(
        component: "ui-test",
        event: "test.teardown.stop-requested",
        testName: testName,
        artifactsDirectoryKey: artifactsKey
      )
      Self.signalRecordingStopIfConfigured()
      appendDiagnosticsTrace(
        component: "ui-test",
        event: "test.teardown.end",
        testName: testName,
        artifactsDirectoryKey: artifactsKey
      )
    }
  }

  override func record(_ issue: XCTIssue) {
    Self.failureTracker.markFailed(name)
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.issue.recorded",
      testName: name,
      details: ["issue": String(describing: issue)],
      artifactsDirectoryKey: Self.artifactsDirectoryKey
    )
    super.record(issue)
  }

  override func tearDownWithError() throws {
    let testName = name
    let artifactsKey = Self.artifactsDirectoryKey
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.teardownWithError.begin",
      testName: testName,
      artifactsDirectoryKey: artifactsKey
    )
    if testRun?.hasSucceeded == false {
      appendDiagnosticsTrace(
        component: "ui-test",
        event: "test.failure.observed",
        testName: testName,
        artifactsDirectoryKey: artifactsKey
      )
    }
    try super.tearDownWithError()
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.teardownWithError.end",
      testName: testName,
      artifactsDirectoryKey: artifactsKey
    )
  }

  override class func tearDown() {
    MainActor.assumeIsolated {
      if let cachedLaunchedApp {
        terminateAndWait(cachedLaunchedApp)
      }
      cachedLaunchedApp = nil
    }
    super.tearDown()
  }

  static func terminateAndWait(_ app: XCUIApplication) {
    switch app.state {
    case .runningForeground, .runningBackground:
      app.terminate()
      let deadline = Date.now.addingTimeInterval(fastActionTimeout)
      while Date.now < deadline, app.state != .notRunning {
        RunLoop.current.run(until: Date.now.addingTimeInterval(fastPollInterval))
      }
    case .notRunning, .unknown:
      break
    @unknown default:
      break
    }
  }

  /// Most-recently-launched NSRunningApplication for the given bundle id, or nil
  /// when nothing matches.
  static func mostRecentRunningApplication(forBundleIdentifier bundleIdentifier: String)
    -> NSRunningApplication?
  {
    let candidates = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier)
    guard !candidates.isEmpty else { return nil }
    return candidates.max { lhs, rhs in
      let lhsDate = lhs.launchDate ?? .distantPast
      let rhsDate = rhs.launchDate ?? .distantPast
      return lhsDate < rhsDate
    }
  }
}

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

  private static func resolveLaunchedPid(forBundleIdentifier bundleIdentifier: String) -> Int32? {
    Self.mostRecentRunningApplication(forBundleIdentifier: bundleIdentifier)?
      .processIdentifier
  }
}
