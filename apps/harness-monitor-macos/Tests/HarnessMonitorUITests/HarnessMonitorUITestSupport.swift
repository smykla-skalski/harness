import XCTest

@MainActor
class HarnessMonitorUITestCase: XCTestCase {
  nonisolated static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"
  nonisolated static let uiTestHostBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  nonisolated static let uiTimeout: TimeInterval = 10
  nonisolated static let actionTimeout: TimeInterval = 2

  override func setUpWithError() throws {
    continueAfterFailure = false
    addTeardownBlock { @MainActor in
      let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      switch app.state {
      case .runningForeground, .runningBackground:
        app.terminate()
        let deadline = Date.now.addingTimeInterval(Self.actionTimeout)
        while Date.now < deadline, app.state != .notRunning {
          RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
        }
      case .notRunning, .unknown:
        break
      @unknown default:
        break
      }
    }
  }
}

extension HarnessMonitorUITestCase {
  func launch(mode: String, additionalEnvironment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launchEnvironment.merge(additionalEnvironment) { _, new in new }
    app.launch()
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

  func openSettings(in app: XCUIApplication) {
    let preferencesRoot = element(
      in: app, identifier: HarnessMonitorUITestAccessibility.preferencesRoot)
    if preferencesRoot.exists {
      return
    }

    app.activate()
    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(
      preferencesRoot.waitForExistence(timeout: Self.actionTimeout),
      "Expected Cmd-, to open the settings window"
    )
  }
}
