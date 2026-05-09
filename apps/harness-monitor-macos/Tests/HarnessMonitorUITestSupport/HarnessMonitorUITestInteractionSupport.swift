import XCTest

extension HarnessMonitorUITestCase {
  func tapButton(in app: XCUIApplication, title: String) {
    if app.state != .runningForeground {
      app.activate()
    }

    let buttonTarget = button(in: app, title: title)
    let presentedTarget = element(in: app, title: title)
    let ready = waitUntil(timeout: Self.fastActionTimeout) {
      (buttonTarget.exists && (buttonTarget.isHittable || !buttonTarget.frame.isEmpty))
        || (presentedTarget.exists && (presentedTarget.isHittable || !presentedTarget.frame.isEmpty))
    }
    guard ready else {
      XCTFail("Failed to tap button titled \(title)")
      return
    }

    if tapButtonElementReliably(in: app, element: buttonTarget) {
      return
    }
    if tapButtonElementReliably(in: app, element: presentedTarget) {
      return
    }

    XCTFail("Failed to tap button titled \(title)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    if app.state != .runningForeground {
      app.activate()
    }

    let target = element(in: app, identifier: identifier)
    let ready = waitUntil(timeout: Self.fastActionTimeout) {
      target.exists && (target.isHittable || !target.frame.isEmpty)
    }
    guard ready else {
      XCTFail("Failed to tap element \(identifier)")
      return
    }

    if tapElementReliably(in: app, element: target) {
      return
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func revealElementInContainer(
    in app: XCUIApplication,
    containerIdentifier: String,
    identifier: String,
    scrollTargetIdentifier: String? = nil,
    title: String? = nil
  ) {
    let container = element(in: app, identifier: containerIdentifier)
    let scrollTarget: XCUIElement
    if let scrollTargetIdentifier, container.exists {
      let containerWindow = window(in: app, containing: container)
      let identifiedScrollTargets =
        containerWindow
        .descendants(matching: .scrollView)
        .matching(identifier: scrollTargetIdentifier)
      let identifiedScrollTarget = identifiedScrollTargets.firstMatch
      if identifiedScrollTarget.exists {
        scrollTarget = identifiedScrollTarget
      } else {
        scrollTarget = revealScrollTarget(in: app, container: container)
      }
    } else {
      if container.exists {
        scrollTarget = revealScrollTarget(in: app, container: container)
      } else {
        scrollTarget = mainWindow(in: app)
      }
    }
    let deadline = Date.now.addingTimeInterval(Self.actionTimeout)

    while Date.now < deadline {
      let target =
        container.exists
        ? descendantElement(in: container, identifier: identifier)
        : element(in: app, identifier: identifier)
      if target.exists && target.isHittable {
        return
      }

      let frameMarker =
        container.exists
        ? descendantFrameElement(in: container, identifier: "\(identifier).frame")
        : element(in: app, identifier: "\(identifier).frame")
      if handleRevealFrameMarker(
        frameMarker,
        in: app,
        scrollTarget: scrollTarget
      ) {
        continue
      }

      if let title {
        let titleMatch = button(in: app, title: title)
        if titleMatch.exists && titleMatch.isHittable {
          return
        }
      }

      dragUp(in: app, element: scrollTarget, distanceRatio: 0.18)
      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to reveal element \(identifier)")
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

  @discardableResult
  func tapButtonElementReliably(in app: XCUIApplication, element: XCUIElement) -> Bool {
    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.click()
      return true
    }

    if element.isHittable {
      element.click()
      return true
    }

    return false
  }

  func buttonTargetIsReady(
    in app: XCUIApplication,
    element: XCUIElement,
    identifier: String
  ) -> Bool {
    guard waitForElement(in: app, element, timeout: Self.fastPollInterval) else {
      return false
    }

    guard element.isEnabled else {
      return false
    }

    if !element.frame.isEmpty {
      return true
    }

    let frameMarker = self.element(in: app, identifier: "\(identifier).frame")
    guard waitForElement(in: app, frameMarker, timeout: Self.fastPollInterval) else {
      return false
    }

    return !frameMarker.frame.isEmpty
  }

  @discardableResult
  func tapElementReliably(in app: XCUIApplication, element: XCUIElement) -> Bool {
    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.click()
      return true
    }

    if element.isHittable {
      element.click()
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

  private func revealScrollTarget(in app: XCUIApplication, container: XCUIElement) -> XCUIElement {
    guard container.exists, !container.frame.isEmpty else {
      return mainWindow(in: app)
    }

    let window = window(in: app, containing: container)
    let nestedScrollViews = container.descendants(matching: .scrollView)

    if let scrollView = largestVisibleScrollTarget(in: nestedScrollViews, window: window) {
      return scrollView
    }

    if container.elementType == .scrollView {
      return container
    }

    if let scrollView = largestVisibleScrollTarget(in: window.scrollViews, window: window) {
      return scrollView
    }

    return container
  }

  private func largestVisibleScrollTarget(
    in query: XCUIElementQuery,
    window: XCUIElement
  ) -> XCUIElement? {
    guard window.exists, !window.frame.isEmpty else {
      return nil
    }

    let windowFrame = window.frame
    let searchCount = min(query.count, 12)
    var bestArea: CGFloat = 0
    var bestMatch: XCUIElement?

    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }

      let visibleFrame = candidate.frame.intersection(windowFrame)
      guard !visibleFrame.isNull, !visibleFrame.isEmpty else { continue }

      let area = visibleFrame.width * visibleFrame.height
      if area > bestArea {
        bestArea = area
        bestMatch = candidate
      }
    }

    return bestMatch
  }

  @discardableResult
  private func dragElementWithinWindow(
    in app: XCUIApplication,
    element: XCUIElement,
    deltaY: CGFloat
  ) -> Bool {
    guard element.exists || element.waitForExistence(timeout: 0.2) else {
      return false
    }

    let containingWindow = window(in: app, containing: element)
    guard containingWindow.exists, !containingWindow.frame.isEmpty else {
      return false
    }

    let visibleFrame = containingWindow.frame.intersection(element.frame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      return false
    }

    let startFrame = visibleFrame.insetBy(
      dx: min(8, max(visibleFrame.width / 4, 0)),
      dy: min(12, max(visibleFrame.height / 4, 0))
    )
    let resolvedStartFrame = startFrame.isEmpty ? visibleFrame : startFrame
    let startPoint = CGPoint(x: resolvedStartFrame.midX, y: resolvedStartFrame.midY)

    let windowBounds = containingWindow.frame.insetBy(dx: 16, dy: 16)
    let endPoint = CGPoint(
      x: startPoint.x,
      y: min(max(startPoint.y + deltaY, windowBounds.minY), windowBounds.maxY)
    )
    guard
      !startPoint.x.isNaN,
      !startPoint.y.isNaN,
      !endPoint.x.isNaN,
      !endPoint.y.isNaN
    else {
      return false
    }

    let origin = containingWindow.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(
      CGVector(
        dx: startPoint.x - containingWindow.frame.minX,
        dy: startPoint.y - containingWindow.frame.minY
      )
    )
    let end = origin.withOffset(
      CGVector(
        dx: endPoint.x - containingWindow.frame.minX,
        dy: endPoint.y - containingWindow.frame.minY
      )
    )
    start.press(forDuration: 0.01, thenDragTo: end)
    return true
  }

  private func handleRevealFrameMarker(
    _ frameMarker: XCUIElement,
    in app: XCUIApplication,
    scrollTarget: XCUIElement
  ) -> Bool {
    guard frameMarker.exists, !frameMarker.frame.isEmpty else {
      return false
    }

    let containingWindow = window(in: app, containing: frameMarker)
    let viewportFrame = scrollTarget.frame.intersection(containingWindow.frame)
    let visibleFrame = viewportFrame.intersection(frameMarker.frame)
    let minimumVisibleHeight = min(24, max(frameMarker.frame.height / 2, 1))
    if !visibleFrame.isNull, !visibleFrame.isEmpty, visibleFrame.height >= minimumVisibleHeight {
      return true
    }

    if frameMarker.frame.midY < viewportFrame.minY {
      if !dragElementWithinWindow(in: app, element: scrollTarget, deltaY: 120) {
        dragDown(in: app, element: scrollTarget, distanceRatio: 0.18)
      }
    } else {
      if !dragElementWithinWindow(in: app, element: scrollTarget, deltaY: -120) {
        dragUp(in: app, element: scrollTarget, distanceRatio: 0.18)
      }
    }
    RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    return true
  }

}
