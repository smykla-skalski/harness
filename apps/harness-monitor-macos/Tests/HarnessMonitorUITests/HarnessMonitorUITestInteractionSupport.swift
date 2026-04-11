import XCTest

extension HarnessMonitorUITestCase {
  func tapPreviewSession(in app: XCUIApplication) {
    tapSession(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func tapSession(in app: XCUIApplication, identifier: String) {
    let sessionRow = sessionTrigger(in: app, identifier: identifier)
    XCTAssertTrue(
      sessionRow.exists || sessionRow.waitForExistence(timeout: Self.actionTimeout)
    )
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
      app.activate()

      let button = button(in: app, identifier: identifier)
      if button.exists || button.waitForExistence(timeout: Self.fastPollInterval) {
        if button.isHittable {
          button.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: button) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func tapButton(in app: XCUIApplication, title: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      app.activate()

      let target = button(in: app, title: title)
      if target.exists || target.waitForExistence(timeout: Self.fastPollInterval) {
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

    XCTFail("Failed to tap button titled \(title)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.fastActionTimeout)

    while Date.now < deadline {
      app.activate()

      let target = element(in: app, identifier: identifier)
      if target.exists || target.waitForExistence(timeout: Self.fastPollInterval) {
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

  func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    let window = window(in: app, containing: element)
    guard window.waitForExistence(timeout: 0.2) else {
      return nil
    }
    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let dx = element.frame.midX - window.frame.minX
    let dy = element.frame.midY - window.frame.minY
    return origin.withOffset(CGVector(dx: dx, dy: dy))
  }
}
