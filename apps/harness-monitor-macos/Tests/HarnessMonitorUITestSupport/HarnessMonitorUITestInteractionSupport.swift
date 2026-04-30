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
    if let start = centerCoordinate(in: app, for: element) {
      let end = start.withOffset(CGVector(dx: 0, dy: -scrollDistance))
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
    if let start = centerCoordinate(in: app, for: element) {
      let end = start.withOffset(CGVector(dx: 0, dy: scrollDistance))
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

  private func preferredTapCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    if let coordinate = clampedWindowCoordinate(in: app, for: element) {
      return coordinate
    }

    if let coordinate = centerCoordinate(in: app, for: element) {
      return coordinate
    }

    let identifier = element.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else {
      return nil
    }

    return visibleFrameMarkerCoordinate(in: app, identifier: identifier)
  }

  @discardableResult
  func clickVisibleFrameMarker(
    in app: XCUIApplication,
    identifier: String
  ) -> Bool {
    guard let coordinate = visibleFrameMarkerCoordinate(in: app, identifier: identifier) else {
      return false
    }
    coordinate.click()
    return true
  }

  private func visibleFrameMarkerCoordinate(
    in app: XCUIApplication,
    identifier: String
  ) -> XCUICoordinate? {
    let frameMarker = self.element(in: app, identifier: "\(identifier).frame")
    guard waitForElement(frameMarker, timeout: Self.fastPollInterval) else {
      return nil
    }

    let containingWindow = window(in: app, containing: frameMarker)
    guard waitForElement(containingWindow, timeout: Self.fastPollInterval) else {
      return nil
    }

    let visibleFrame = containingWindow.frame.intersection(frameMarker.frame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      return nil
    }

    let clampedFrame = visibleFrame.insetBy(
      dx: min(4, max(visibleFrame.width / 4, 0)),
      dy: min(4, max(visibleFrame.height / 4, 0))
    )
    let targetFrame = clampedFrame.isEmpty ? visibleFrame : clampedFrame
    let targetPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard !targetPoint.x.isNaN, !targetPoint.y.isNaN else {
      return nil
    }

    let origin = containingWindow.coordinate(withNormalizedOffset: .zero)
    return origin.withOffset(
      CGVector(
        dx: targetPoint.x - containingWindow.frame.minX,
        dy: targetPoint.y - containingWindow.frame.minY
      )
    )
  }

  private func clampedWindowCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    guard element.exists || element.waitForExistence(timeout: 0.2) else {
      return nil
    }

    let containingWindow = window(in: app, containing: element)
    guard containingWindow.exists else {
      return nil
    }

    let visibleFrame = containingWindow.frame.intersection(element.frame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      return nil
    }

    let clampedFrame = visibleFrame.insetBy(
      dx: min(4, max(visibleFrame.width / 4, 0)),
      dy: min(4, max(visibleFrame.height / 4, 0))
    )
    let targetFrame = clampedFrame.isEmpty ? visibleFrame : clampedFrame
    let targetPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    let origin = containingWindow.coordinate(withNormalizedOffset: .zero)

    return origin.withOffset(
      CGVector(
        dx: targetPoint.x - containingWindow.frame.minX,
        dy: targetPoint.y - containingWindow.frame.minY
      )
    )
  }

  func invokeMenuItem(
    in app: XCUIApplication,
    menu menuTitle: String,
    title: String
  ) {
    app.activate()
    let menuBarItem = app.menuBars.menuBarItems[menuTitle].firstMatch
    XCTAssertTrue(
      waitForElement(menuBarItem, timeout: Self.actionTimeout),
      "\(menuTitle) menu should exist in the menu bar"
    )
    menuBarItem.click()

    let menuItem = app.menuItems[title].firstMatch
    XCTAssertTrue(
      waitForElement(menuItem, timeout: Self.actionTimeout),
      "\(title) menu item should appear after opening the \(menuTitle) menu"
    )
    menuItem.click()
  }
}
