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
      // launch(mode:) already cleans up any leftover UI-test host before the next
      // launch. Re-terminating here keeps XCTest automation alive after the app
      // has already closed.
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
      if let cached = cachedLaunchedApp {
        terminateAndWait(cached)
        cachedLaunchedApp = nil
      }
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
