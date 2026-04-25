import Foundation
import XCTest

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
  nonisolated static let fastActionTimeout: TimeInterval = 0.75
  nonisolated static let fastPollInterval: TimeInterval = 0.05

  override func setUpWithError() throws {
    continueAfterFailure = false
    addTeardownBlock { @MainActor in
      let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      switch app.state {
      case .runningForeground, .runningBackground:
        app.terminate()
        let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)
        while Date.now < deadline, app.state != .notRunning {
          RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
        }
      case .notRunning, .unknown:
        break
      @unknown default:
        break
      }
      Self.signalRecordingStopIfConfigured()
    }
  }

  override func tearDownWithError() throws {
    if testRun?.hasSucceeded == false {
      let snapshotName = "failure-final-\(UUID().uuidString.lowercased())"
      MainActor.assumeIsolated {
        let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
        recordStandaloneDiagnosticsSnapshot(
          in: app,
          named: snapshotName,
          artifactsDirectoryKey: Self.artifactsDirectoryKey
        )
      }
    }
    try super.tearDownWithError()
  }
}

extension HarnessMonitorUITestCase {
  func launch(mode: String, additionalEnvironment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
    app.launchEnvironment[Self.launchModeKey] = mode
    guard configureIsolatedDataHome(for: app, purpose: mode) else {
      return app
    }
    app.launchEnvironment.merge(additionalEnvironment) { _, new in new }
    guard armRecordingStartIfConfigured() else {
      return app
    }
    app.launch()
    guard waitForRecordingStartIfConfigured() else {
      return app
    }
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }

        return app.state == .runningForeground || self.mainWindow(in: app).exists
      }
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        let window = self.mainWindow(in: app)
        app.activate()
        return
          window.exists
          && window.frame.width > 0
          && window.frame.height > 0
      }
    )
    return app
  }

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

    do {
      try FileManager.default.createDirectory(
        at: controlDirectory,
        withIntermediateDirectories: true
      )
      for marker in [startRequest, startAck, stopRequest] {
        try? FileManager.default.removeItem(at: marker)
      }
      try Data().write(to: startRequest, options: .atomic)
    } catch {
      let suffix = context.isEmpty ? "" : "\n\(context)"
      XCTFail(
        "Failed to arm recording start markers in \(controlDirectory.path): \(error)\(suffix)",
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
    if waitUntil(
      timeout: Self.uiTimeout,
      condition: {
        FileManager.default.fileExists(atPath: startAck.path)
      }
    ) {
      return true
    }

    let suffix = context.isEmpty ? "" : "\n\(context)"
    XCTFail(
      "Timed out waiting for recording start ack at \(startAck.path)\(suffix)",
      file: file,
      line: line
    )
    return false
  }

  private static func signalRecordingStopIfConfigured() {
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

  private static func recordingControlDirectory() -> URL? {
    guard
      let rawValue = ProcessInfo.processInfo.environment[Self.recordingControlDirectoryKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      rawValue.isEmpty == false
    else {
      return nil
    }
    return URL(fileURLWithPath: rawValue, isDirectory: true)
  }

  @discardableResult
  func configureIsolatedDataHome(
    for app: XCUIApplication,
    purpose: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorUITests", isDirectory: true)
      .appendingPathComponent(
        storageDirectoryName(for: purpose),
        isDirectory: true
      )

    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try seedObservabilityConfig(into: root)
    } catch {
      XCTFail(
        "Failed to create isolated UI-test data home at \(root.path): \(error)",
        file: file,
        line: line
      )
      return false
    }

    app.launchEnvironment[Self.daemonDataHomeKey] = root.path
    addTeardownBlock { @MainActor in
      try? FileManager.default.removeItem(at: root)
    }
    return true
  }

  private func storageDirectoryName(for purpose: String) -> String {
    let testName = storagePathComponent(name)
    let purposeName = storagePathComponent(purpose)
    return "\(testName)-\(purposeName)-\(UUID().uuidString)"
  }

  private func storagePathComponent(_ value: String) -> String {
    let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let component = value.unicodeScalars
      .map { allowedScalars.contains($0) ? String($0) : "-" }
      .joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return component.isEmpty ? "launch" : component
  }

  private func seedObservabilityConfig(into root: URL) throws {
    let targetURL =
      root
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")

    try FileManager.default.createDirectory(
      at: targetURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: targetURL.path) {
      try FileManager.default.removeItem(at: targetURL)
    }

    try defaultObservabilityConfigBody().write(
      to: targetURL,
      atomically: true,
      encoding: .utf8
    )
  }

  private func defaultObservabilityConfigBody() -> String {
    [
      "{",
      "  \"enabled\": true,",
      "  \"grpc_endpoint\": \"http://127.0.0.1:4317\",",
      "  \"http_endpoint\": \"http://127.0.0.1:4318\",",
      "  \"grafana_url\": \"http://127.0.0.1:3000\",",
      "  \"tempo_url\": \"http://127.0.0.1:3200\",",
      "  \"loki_url\": \"http://127.0.0.1:3100\",",
      "  \"prometheus_url\": \"http://127.0.0.1:9090\",",
      "  \"pyroscope_url\": \"http://127.0.0.1:4040\",",
      "  \"monitor_smoke_enabled\": false,",
      "  \"headers\": {}",
      "}",
    ].joined(separator: "\n")
  }

  func openSettings(in app: XCUIApplication) {
    let preferencesRoot = element(
      in: app, identifier: HarnessMonitorUITestAccessibility.preferencesRoot)
    if preferencesRoot.exists {
      return
    }

    app.activate()
    app.typeKey(",", modifierFlags: .command)
  }
}
