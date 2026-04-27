import XCTest

extension HarnessMonitorUITestCase {
  func launch(mode: String, additionalEnvironment: [String: String] = [:]) -> XCUIApplication {
    recordDiagnosticsTrace(
      event: "launch.start",
      details: [
        "mode": mode,
        "reuse_cached_app": String(Self.reuseLaunchedApp),
      ]
    )
    if let cached = reusableCachedApp(mode: mode) {
      return cached
    }

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
    recordDiagnosticsTrace(event: "launch.app-launched", app: app, details: ["mode": mode])
    XCTAssertTrue(
      waitForLaunchForeground(app, mode: mode),
      """
      UI-test host never became foreground.
      mode=\(mode)
      trace=\(diagnosticsTracePath() ?? "unavailable")
      """
    )
    guard provideRecordingPidIfConfigured(for: app) else {
      return app
    }
    guard waitForRecordingStartIfConfigured() else {
      return app
    }

    recordDiagnosticsTrace(event: "launch.recording-started", app: app, details: ["mode": mode])
    let windowReady = waitForLaunchWindow(app, mode: mode)
    XCTAssertTrue(
      windowReady,
      """
      UI-test host never produced a main window.
      mode=\(mode)
      trace=\(diagnosticsTracePath() ?? "unavailable")
      """
    )
    if Self.reuseLaunchedApp {
      Self.cachedLaunchedApp = app
    }
    if windowReady {
      recordDiagnosticsTrace(event: "launch.window-ready", app: app, details: ["mode": mode])
    }
    return app
  }

  private func reusableCachedApp(mode: String) -> XCUIApplication? {
    guard
      Self.reuseLaunchedApp,
      let cached = Self.cachedLaunchedApp,
      cached.state == .runningForeground || cached.state == .runningBackground
    else {
      return nil
    }

    recordDiagnosticsTrace(
      event: "launch.reuse.cached",
      app: cached,
      details: ["mode": mode]
    )
    cached.activate()
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        cached.state == .runningForeground
      }
    )
    return cached
  }

  private func waitForLaunchForeground(_ app: XCUIApplication, mode: String) -> Bool {
    let foregroundReady = waitUntil(timeout: Self.uiTimeout) {
      if app.state != .runningForeground {
        app.activate()
      }

      return app.state == .runningForeground || self.mainWindow(in: app).exists
    }
    if !foregroundReady {
      recordDiagnosticsTrace(
        event: "launch.foreground.timeout",
        app: app,
        details: ["mode": mode]
      )
    }
    return foregroundReady
  }

  private func waitForLaunchWindow(_ app: XCUIApplication, mode: String) -> Bool {
    let windowReady = waitUntil(timeout: Self.uiTimeout) {
      let window = self.mainWindow(in: app)
      app.activate()
      return
        window.exists
        && window.frame.width > 0
        && window.frame.height > 0
    }
    if !windowReady {
      recordDiagnosticsTrace(
        event: "launch.window.timeout",
        app: app,
        details: ["mode": mode]
      )
    }
    return windowReady
  }
}
