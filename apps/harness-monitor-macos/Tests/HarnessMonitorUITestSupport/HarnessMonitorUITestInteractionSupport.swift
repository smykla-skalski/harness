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

      let button = button(in: app, identifier: identifier)
      if waitForElement(button, timeout: Self.fastPollInterval) {
        if tapButtonElementReliably(in: app, element: button) {
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

  func tapButton(in app: XCUIApplication, title: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let buttonTarget = button(in: app, title: title)
      if waitForElement(buttonTarget, timeout: Self.fastPollInterval) {
        if tapButtonElementReliably(in: app, element: buttonTarget) {
          return
        }

      }

      let presentedTarget = element(in: app, title: title)
      if waitForElement(presentedTarget, timeout: Self.fastPollInterval) {
        if tapButtonElementReliably(in: app, element: presentedTarget) {
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap button titled \(title)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let target = element(in: app, identifier: identifier)
      if waitForElement(target, timeout: Self.fastPollInterval) {
        if tapElementReliably(in: app, element: target) {
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func dragUp(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let scrollDistance = max(120, element.frame.height * distanceRatio)
    if let (start, end) = clampedWindowDragPath(
      in: app,
      for: element,
      deltaY: -scrollDistance
    ) {
      start.press(forDuration: 0.01, thenDragTo: end)
      return
    }

    if element.isHittable {
      element.scroll(byDeltaX: 0, deltaY: -scrollDistance)
      return
    }

    XCTFail("Failed to resolve drag origin for \(element)")
  }

  func dragDown(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let scrollDistance = max(120, element.frame.height * distanceRatio)
    if let (start, end) = clampedWindowDragPath(
      in: app,
      for: element,
      deltaY: scrollDistance
    ) {
      start.press(forDuration: 0.01, thenDragTo: end)
      return
    }

    if element.isHittable {
      element.scroll(byDeltaX: 0, deltaY: scrollDistance)
      return
    }

    XCTFail("Failed to resolve drag origin for \(element)")
  }

  func waitUntil(
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout,
    pollInterval: TimeInterval = HarnessMonitorUITestCase.fastPollInterval,
    condition: @escaping () -> Bool
  ) -> Bool {
    if condition() {
      return true
    }

    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      let remaining = deadline.timeIntervalSinceNow
      let nextPollInterval = min(pollInterval, max(remaining, 0.01))
      RunLoop.current.run(until: Date.now.addingTimeInterval(nextPollInterval))

      if condition() {
        return true
      }
    }

    return condition()
  }

  func waitForElement(
    _ element: XCUIElement,
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout
  ) -> Bool {
    element.exists || element.waitForExistence(timeout: timeout)
  }

  @discardableResult
  private func tapButtonElementReliably(in app: XCUIApplication, element: XCUIElement) -> Bool {
    if element.isHittable {
      element.click()
      return true
    }

    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.click()
      return true
    }

    return false
  }

  private func buttonTargetIsReady(
    in app: XCUIApplication,
    element: XCUIElement,
    identifier: String
  ) -> Bool {
    guard waitForElement(element, timeout: Self.fastPollInterval) else {
      return false
    }

    guard element.isEnabled else {
      return false
    }

    if !element.frame.isEmpty {
      return true
    }

    let frameMarker = self.element(in: app, identifier: "\(identifier).frame")
    guard waitForElement(frameMarker, timeout: Self.fastPollInterval) else {
      return false
    }

    return !frameMarker.frame.isEmpty
  }

  @discardableResult
  func tapElementReliably(in app: XCUIApplication, element: XCUIElement) -> Bool {
    if element.isHittable {
      element.click()
      return true
    }

    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.click()
      return true
    }

    return false
  }

  @discardableResult
  func rightClickElementReliably(in app: XCUIApplication, element: XCUIElement) -> Bool {
    if element.isHittable {
      element.rightClick()
      return true
    }

    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.rightClick()
      return true
    }

    return false
  }

  func sessionRowIsSelected(_ sessionRow: XCUIElement) -> Bool {
    guard sessionRow.exists else { return false }

    if let rawValue = sessionRow.value as? String {
      return
        rawValue
        .split(separator: ",")
        .contains { component in
          component.trimmingCharacters(in: .whitespacesAndNewlines) == "selected"
        }
    }

    if let rawValue = sessionRow.value as? NSNumber {
      return rawValue.boolValue
    }

    return false
  }

}
