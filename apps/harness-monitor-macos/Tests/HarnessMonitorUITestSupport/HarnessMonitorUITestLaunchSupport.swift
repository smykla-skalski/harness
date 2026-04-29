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
    let contentReady = waitForLaunchContent(app, mode: mode)
    XCTAssertTrue(
      contentReady,
      """
      UI-test host never finished loading app chrome.
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
    if contentReady {
      recordDiagnosticsTrace(event: "launch.content-ready", app: app, details: ["mode": mode])
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
    recordDiagnosticsTrace(
      event: "launch.reuse.activate",
      app: cached,
      details: ["mode": mode]
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        cached.state == .runningForeground
      }
    )
    return cached
  }

  private func waitForLaunchForeground(_ app: XCUIApplication, mode: String) -> Bool {
    let foregroundReady = waitUntil(timeout: Self.uiTimeout) {
      return app.state == .runningForeground || self.mainWindow(in: app).exists
    }
    if !foregroundReady {
      recordDiagnosticsTrace(
        event: "launch.foreground.activate-fallback",
        app: app,
        details: ["mode": mode]
      )
      app.activate()
      if waitUntil(timeout: Self.fastActionTimeout, condition: {
        app.state == .runningForeground || self.mainWindow(in: app).exists
      }) {
        return true
      }
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
      return
        window.exists
        && window.frame.width > 0
        && window.frame.height > 0
    }
    if !windowReady {
      recordDiagnosticsTrace(
        event: "launch.window.activate-fallback",
        app: app,
        details: ["mode": mode]
      )
      app.activate()
      if waitUntil(timeout: Self.fastActionTimeout, condition: {
        let window = self.mainWindow(in: app)
        return
          window.exists
          && window.frame.width > 0
          && window.frame.height > 0
      }) {
        return true
      }
      recordDiagnosticsTrace(
        event: "launch.window.timeout",
        app: app,
        details: ["mode": mode]
      )
    }
    return windowReady
  }

  private func waitForLaunchContent(_ app: XCUIApplication, mode: String) -> Bool {
    let contentReady = waitUntil(timeout: Self.uiTimeout) {
      let window = self.mainWindow(in: app)
      let appChrome = self.appChromeRoot(in: app)
      return
        window.exists
        && window.frame.width > 0
        && window.frame.height > 0
        && appChrome.exists
    }
    if !contentReady {
      recordDiagnosticsTrace(
        event: "launch.content.timeout",
        app: app,
        details: ["mode": mode]
      )
    }
    return contentReady
  }
}
