import XCTest

extension HarnessMonitorUITestCase {
  func tapPreviewSession(in app: XCUIApplication) {
    tapSession(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func tapSession(in app: XCUIApplication, identifier: String) {
    clickSession(in: app, identifier: identifier)
  }

  func clickSession(
    in app: XCUIApplication,
    identifier: String,
    allowAlreadySelected: Bool = false
  ) {
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
    guard allowAlreadySelected || !sessionRowIsSelected(sessionRow) else { return }
    if app.state != .runningForeground {
      app.activate()
    }
    if let coordinate = preferredTapCoordinate(in: app, for: sessionRow) {
      coordinate.click()
      recordDiagnosticsTrace(
        event: "tap-session.hittable",
        app: app,
        details: ["identifier": identifier]
      )
      return
    }
    if let coordinate = centerCoordinate(in: app, for: sessionRow) {
      coordinate.click()
      recordDiagnosticsTrace(
        event: "tap-session.coordinate",
        app: app,
        details: ["identifier": identifier]
      )
      return
    }
    if sessionRow.isHittable {
      sessionRow.click()
      recordDiagnosticsTrace(
        event: "tap-session.element-click",
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

  #if os(macOS)
    func modifierClickSession(
      in app: XCUIApplication,
      identifier: String,
      modifierFlags: XCUIElement.KeyModifierFlags,
      settleAfterClick: Bool = true
    ) {
      let sessionRow = sessionTrigger(in: app, identifier: identifier)
      let elementCenterCoordinate = centerCoordinate(in: app, for: sessionRow)
      let fallbackCoordinate = preferredTapCoordinate(in: app, for: sessionRow)
      let exists =
        waitForElement(sessionRow, timeout: Self.fastActionTimeout)
        || elementCenterCoordinate != nil
        || fallbackCoordinate != nil
      XCTAssertTrue(
        exists,
        """
        Expected session row \(identifier)
        trace=\(diagnosticsTracePath() ?? "unavailable")
        """
      )
      guard exists else { return }

      if app.state != .runningForeground {
        app.activate()
      }

      recordDiagnosticsTrace(
        event: "tap-session.modifier.begin",
        app: app,
        details: [
          "identifier": identifier,
          "element_type": "\(sessionRow.elementType.rawValue)",
          "is_hittable": "\(sessionRow.isHittable)",
          "modifier_flags": "\(modifierFlags.rawValue)",
          "coordinate_source": {
            if elementCenterCoordinate != nil {
              return "element-center"
            }
            if fallbackCoordinate != nil {
              return "fallback"
            }
            return "element-click"
          }(),
        ]
      )

      if let elementCenterCoordinate {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          elementCenterCoordinate.click()
        }
      } else if let fallbackCoordinate {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          fallbackCoordinate.click()
        }
      } else {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          sessionRow.click()
        }
      }
      if settleAfterClick {
        RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
      }
      recordDiagnosticsTrace(
        event: "tap-session.modifier.end",
        app: app,
        details: [
          "identifier": identifier,
          "value_after": String(describing: sessionRow.value ?? "nil"),
        ]
      )
    }
  #endif

  func terminateIfRunning(_ app: XCUIApplication) {
    HarnessMonitorUITestCase.terminateAndWait(app)
  }

  func tapButton(in app: XCUIApplication, identifier: String) {
    if app.state != .runningForeground {
      app.activate()
    }

    guard waitForButtonReady(in: app, identifier: identifier, timeout: Self.fastActionTimeout)
    else {
      XCTFail("Failed to tap button \(identifier)")
      return
    }

    let buttonTarget = button(in: app, identifier: identifier)
    if buttonTargetIsReady(in: app, element: buttonTarget, identifier: identifier),
      tapButtonElementReliably(in: app, element: buttonTarget)
    {
      return
    }

    let genericTarget = element(in: app, identifier: identifier)
    if buttonTargetIsReady(in: app, element: genericTarget, identifier: identifier),
      tapButtonElementReliably(in: app, element: genericTarget)
    {
      return
    }

    if clickVisibleFrameMarker(in: app, identifier: identifier) {
      return
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
      if app.state == .notRunning {
        return false
      }
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
