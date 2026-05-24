import XCTest

extension HarnessMonitorUITestCase {
  private func uiTestHostIsRunning(_ app: XCUIApplication) -> Bool {
    app.state != .notRunning
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

  func waitUntil(
    in app: XCUIApplication,
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout,
    pollInterval: TimeInterval = HarnessMonitorUITestCase.fastPollInterval,
    condition: @escaping () -> Bool
  ) -> Bool {
    guard uiTestHostIsRunning(app) else {
      return false
    }
    if condition() {
      return true
    }

    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      guard uiTestHostIsRunning(app) else {
        return false
      }
      let remaining = deadline.timeIntervalSinceNow
      let nextPollInterval = min(pollInterval, max(remaining, 0.01))
      RunLoop.current.run(until: Date.now.addingTimeInterval(nextPollInterval))

      guard uiTestHostIsRunning(app) else {
        return false
      }
      if condition() {
        return true
      }
    }

    guard uiTestHostIsRunning(app) else {
      return false
    }
    return condition()
  }

  func waitForElement(
    _ element: XCUIElement,
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout
  ) -> Bool {
    element.exists || element.waitForExistence(timeout: timeout)
  }

  func waitForElement(
    in app: XCUIApplication,
    _ element: XCUIElement,
    timeout: TimeInterval = HarnessMonitorUITestCase.actionTimeout
  ) -> Bool {
    waitUntil(in: app, timeout: timeout) {
      element.exists
    }
  }
}
