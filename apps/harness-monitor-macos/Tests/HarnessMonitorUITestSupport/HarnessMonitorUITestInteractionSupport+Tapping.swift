import XCTest

extension HarnessMonitorUITestCase {
  func tapPreviewSession(in app: XCUIApplication) {
    tapSession(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func tapSession(in app: XCUIApplication, identifier: String) {
    let sessionRow = sessionTrigger(in: app, identifier: identifier)
    recordDiagnosticsTrace(
      event: "tap-session.begin",
      app: app,
      details: ["identifier": identifier]
    )
    let exists = waitForElement(sessionRow, timeout: Self.fastActionTimeout)
    if !exists {
      recordDiagnosticsTrace(
        event: "tap-session.timeout",
        app: app,
        details: ["identifier": identifier]
      )
    }
    XCTAssertTrue(
      exists,
      """
      Expected session row \(identifier)
      trace=\(diagnosticsTracePath() ?? "unavailable")
      """
    )
    guard !sessionRowIsSelected(sessionRow) else { return }
    if sessionRow.isHittable {
      sessionRow.tap()
      recordDiagnosticsTrace(
        event: "tap-session.hittable",
        app: app,
        details: ["identifier": identifier]
      )
      return
    }
    if let coordinate = centerCoordinate(in: app, for: sessionRow) {
      coordinate.tap()
      recordDiagnosticsTrace(
        event: "tap-session.coordinate",
        app: app,
        details: ["identifier": identifier]
      )
      return
    }
    recordDiagnosticsTrace(
      event: "tap-session.failed",
      app: app,
      details: ["identifier": identifier]
    )
    XCTFail("Failed to tap session row \(identifier)")
  }

  func terminateIfRunning(_ app: XCUIApplication) {
    HarnessMonitorUITestCase.terminateAndWait(app)
  }

  func tapButton(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let buttonTarget = button(in: app, identifier: identifier)
      if waitForElement(buttonTarget, timeout: Self.fastPollInterval) {
        if tapButtonElementReliably(in: app, element: buttonTarget) {
          return
        }
        if clickVisibleFrameMarker(in: app, identifier: identifier) {
          return
        }
      }

      let genericTarget = element(in: app, identifier: identifier)
      if waitForElement(genericTarget, timeout: Self.fastPollInterval) {
        if tapButtonElementReliably(in: app, element: genericTarget) {
          return
        }
        if clickVisibleFrameMarker(in: app, identifier: identifier) {
          return
        }
      }

      if clickVisibleFrameMarker(in: app, identifier: identifier) {
        return
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func waitForButtonReady(
    in app: XCUIApplication,
    identifier: String,
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let buttonTarget = button(in: app, identifier: identifier)
      if buttonTargetIsReady(in: app, element: buttonTarget, identifier: identifier) {
        return true
      }

      let genericTarget = element(in: app, identifier: identifier)
      if buttonTargetIsReady(in: app, element: genericTarget, identifier: identifier) {
        return true
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    return false
  }
}
