import XCTest

extension HarnessMonitorUITestCase {
  func tapPreviewSession(in app: XCUIApplication) {
    tapSession(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func tapSession(in app: XCUIApplication, identifier: String) {
    let sessionRow = sessionTrigger(in: app, identifier: identifier)
    XCTAssertTrue(
      waitForElement(sessionRow, timeout: Self.fastActionTimeout)
    )
    guard !sessionRowIsSelected(sessionRow) else { return }
    if sessionRow.isHittable {
      sessionRow.tap()
      return
    }
    if let coordinate = centerCoordinate(in: app, for: sessionRow) {
      coordinate.tap()
      return
    }
    XCTFail("Failed to tap session row \(identifier)")
  }

  func terminateIfRunning(_ app: XCUIApplication) {
    switch app.state {
    case .runningForeground, .runningBackground:
      app.terminate()
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          app.state == .notRunning
        }
      )
    case .notRunning, .unknown:
      break
    @unknown default:
      break
    }
  }

  func tapButton(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let button = button(in: app, identifier: identifier)
      if waitForElement(button, timeout: Self.fastPollInterval) {
        if let coordinate = centerCoordinate(in: app, for: button) {
          coordinate.tap()
          return
        }

        if button.isHittable {
          button.tap()
          return
        }
      }

      let genericTarget = element(in: app, identifier: identifier)
      if waitForElement(genericTarget, timeout: Self.fastPollInterval) {
        if genericTarget.isHittable {
          genericTarget.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: genericTarget) {
          coordinate.tap()
          return
        }
      }

      let frameMarker = element(in: app, identifier: "\(identifier).frame")
      if waitForElement(frameMarker, timeout: Self.fastPollInterval),
        let coordinate = centerCoordinate(in: app, for: frameMarker)
      {
        coordinate.tap()
        return
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func tapButton(in app: XCUIApplication, title: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }

      let buttonTarget = button(in: app, title: title)
      if waitForElement(buttonTarget, timeout: Self.fastPollInterval) {
        if let coordinate = centerCoordinate(in: app, for: buttonTarget) {
          coordinate.tap()
          return
        }

        if buttonTarget.isHittable {
          buttonTarget.tap()
          return
        }

      }

      let presentedTarget = element(in: app, title: title)
      if waitForElement(presentedTarget, timeout: Self.fastPollInterval) {
        if presentedTarget.isHittable {
          presentedTarget.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: presentedTarget) {
          coordinate.tap()
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
        if target.isHittable {
          target.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: target) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func dragUp(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let scrollDistance = max(120, element.frame.height * distanceRatio)
    if element.isHittable {
      element.scroll(byDeltaX: 0, deltaY: -scrollDistance)
      return
    }

    guard let start = centerCoordinate(in: app, for: element) else {
      XCTFail("Failed to resolve drag origin for \(element)")
      return
    }

    let end = start.withOffset(CGVector(dx: 0, dy: -scrollDistance))
    start.press(forDuration: 0.01, thenDragTo: end)
  }

  func dragDown(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let scrollDistance = max(120, element.frame.height * distanceRatio)
    if element.isHittable {
      element.scroll(byDeltaX: 0, deltaY: scrollDistance)
      return
    }

    guard let start = centerCoordinate(in: app, for: element) else {
      XCTFail("Failed to resolve drag origin for \(element)")
      return
    }

    let end = start.withOffset(CGVector(dx: 0, dy: scrollDistance))
    start.press(forDuration: 0.01, thenDragTo: end)
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

  func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    _ = app
    guard element.exists || element.waitForExistence(timeout: 0.2) else {
      return nil
    }
    return element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
  }
}
