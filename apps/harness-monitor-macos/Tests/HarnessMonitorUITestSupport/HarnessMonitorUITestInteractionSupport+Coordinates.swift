import XCTest

extension HarnessMonitorUITestCase {
  func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    _ = app
    guard element.exists || element.waitForExistence(timeout: 0.2) else {
      return nil
    }
    // Empty-frame accessibility nodes frequently appear before SwiftUI finishes
    // laying out the visible control. Defer those to explicit frame markers so
    // we do not keep clicking a bogus coordinate while the real target exists.
    guard !element.frame.isEmpty else {
      return nil
    }
    return element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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

  func hasVisibleFrameMarker(
    in app: XCUIApplication,
    identifier: String
  ) -> Bool {
    visibleFrameMarkerCoordinate(in: app, identifier: identifier) != nil
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

  func clampedWindowDragPath(
    in app: XCUIApplication,
    for element: XCUIElement,
    deltaY: CGFloat
  ) -> (start: XCUICoordinate, end: XCUICoordinate)? {
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
      dx: min(8, max(visibleFrame.width / 4, 0)),
      dy: min(12, max(visibleFrame.height / 4, 0))
    )
    let targetFrame = clampedFrame.isEmpty ? visibleFrame : clampedFrame
    let startPoint = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    let rawEndY = startPoint.y + deltaY
    let minEndY = targetFrame.minY + 2
    let maxEndY = targetFrame.maxY - 2
    let endPoint = CGPoint(
      x: startPoint.x,
      y: min(max(rawEndY, minEndY), maxEndY)
    )
    guard
      !startPoint.x.isNaN,
      !startPoint.y.isNaN,
      !endPoint.x.isNaN,
      !endPoint.y.isNaN
    else {
      return nil
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
    return (start, end)
  }
}
