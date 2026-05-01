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

private struct HarnessMonitorUITestTeardownContext: Sendable {
  let testName: String
  let artifactsDirectoryKey: String
  let reuseLaunchedApp: Bool
  let failureTracker: HarnessMonitorUITestFailureTracker
  let uiTestHostBundleIdentifier: String
}

struct HarnessMonitorUITestLaunchEnvironmentEntry: Equatable {
  let key: String
  let value: String
}

struct HarnessMonitorUITestLaunchSignature: Equatable {
  let mode: String
  let environment: [HarnessMonitorUITestLaunchEnvironmentEntry]

  init(mode: String, additionalEnvironment: [String: String]) {
    self.mode = mode
    environment =
      additionalEnvironment
      .sorted { lhs, rhs in
        if lhs.key == rhs.key {
          return lhs.value < rhs.value
        }
        return lhs.key < rhs.key
      }
      .map { HarnessMonitorUITestLaunchEnvironmentEntry(key: $0.key, value: $0.value) }
  }

  var summary: String {
    guard !environment.isEmpty else {
      return mode
    }
    let environmentSummary =
      environment
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ",")
    return "\(mode) [\(environmentSummary)]"
  }
}

struct HarnessMonitorUITestCachedLaunch {
  let app: XCUIApplication
  let signature: HarnessMonitorUITestLaunchSignature
  let dataHomeRoot: URL
}

@MainActor
private func performHarnessMonitorUITestTeardown(
  _ context: HarnessMonitorUITestTeardownContext
) {
  appendDiagnosticsTrace(
    component: "ui-test",
    event: "test.teardown.begin",
    testName: context.testName,
    artifactsDirectoryKey: context.artifactsDirectoryKey
  )
  if context.failureTracker.takeFailure(for: context.testName) {
    let snapshotName = "failure-final-\(UUID().uuidString.lowercased())"
    let app = XCUIApplication(bundleIdentifier: context.uiTestHostBundleIdentifier)
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.failure.snapshot",
      testName: context.testName,
      details: ["snapshot": snapshotName],
      artifactsDirectoryKey: context.artifactsDirectoryKey
    )
    recordStandaloneDiagnosticsSnapshot(
      in: app,
      named: snapshotName,
      artifactsDirectoryKey: context.artifactsDirectoryKey
    )
  }
  if !context.reuseLaunchedApp {
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.teardown.terminate-app",
      testName: context.testName,
      artifactsDirectoryKey: context.artifactsDirectoryKey
    )
    let launchedApp = XCUIApplication(bundleIdentifier: context.uiTestHostBundleIdentifier)
    HarnessMonitorUITestCase.terminateAndWait(launchedApp)
  }
  appendDiagnosticsTrace(
    component: "ui-test",
    event: "test.teardown.stop-requested",
    testName: context.testName,
    artifactsDirectoryKey: context.artifactsDirectoryKey
  )
  HarnessMonitorUITestCase.signalRecordingStopIfConfigured()
  appendDiagnosticsTrace(
    component: "ui-test",
    event: "test.teardown.end",
    testName: context.testName,
    artifactsDirectoryKey: context.artifactsDirectoryKey
  )
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

  static var cachedLaunch: HarnessMonitorUITestCachedLaunch?

  override func setUpWithError() throws {
    continueAfterFailure = false
    let teardownContext = HarnessMonitorUITestTeardownContext(
      testName: name,
      artifactsDirectoryKey: Self.artifactsDirectoryKey,
      reuseLaunchedApp: Self.reuseLaunchedApp,
      failureTracker: Self.failureTracker,
      uiTestHostBundleIdentifier: Self.uiTestHostBundleIdentifier
    )
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.setup",
      testName: teardownContext.testName,
      artifactsDirectoryKey: teardownContext.artifactsDirectoryKey
    )
    addTeardownBlock { @MainActor [teardownContext] in
      performHarnessMonitorUITestTeardown(teardownContext)
    }
  }

  override func record(_ issue: XCTIssue) {
    let testName = name
    let artifactsKey = Self.artifactsDirectoryKey
    Self.failureTracker.markFailed(testName)
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.issue.recorded",
      testName: testName,
      details: ["issue": String(describing: issue)],
      artifactsDirectoryKey: artifactsKey
    )
    super.record(issue)
    appendDiagnosticsTrace(
      component: "ui-test",
      event: "test.issue.fail-fast-stop",
      testName: testName,
      artifactsDirectoryKey: artifactsKey
    )
    MainActor.assumeIsolated {
      Self.signalRecordingStopIfConfigured()
      let launchedApp = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      Self.terminateAndWait(launchedApp)
    }
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
      discardCachedLaunch()
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

  static func discardCachedLaunch() {
    guard let cachedLaunch else { return }
    terminateAndWait(cachedLaunch.app)
    cleanupIsolatedDataHome(at: cachedLaunch.dataHomeRoot)
    Self.cachedLaunch = nil
  }
}

extension HarnessMonitorUITestCase {
}
