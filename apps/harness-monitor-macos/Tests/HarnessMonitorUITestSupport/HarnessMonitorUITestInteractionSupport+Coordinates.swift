import Foundation
import XCTest

private struct CoordinateResolutionContext {
  let source: String
  let origin: String
  let containingWindow: XCUIElement
  let targetFrame: CGRect
  let visibleFrame: CGRect
  let targetPoint: CGPoint
}

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

  @discardableResult
  func clickVisibleFrameMarker(
    in app: XCUIApplication,
    identifier: String,
    normalizedOffset: CGVector
  ) -> Bool {
    guard
      let coordinate = visibleFrameMarkerCoordinate(
        in: app,
        identifier: identifier,
        normalizedOffset: normalizedOffset
      )
    else {
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

  func preferredTapCoordinate(
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
    if !identifier.isEmpty,
      let coordinate = visibleFrameMarkerCoordinate(in: app, identifier: identifier)
    {
      return coordinate
    }
    return nil
  }

  private func visibleFrameMarkerCoordinate(
    in app: XCUIApplication,
    identifier: String,
    normalizedOffset: CGVector = CGVector(dx: 0.5, dy: 0.5)
  ) -> XCUICoordinate? {
    let frameMarker = frameElement(in: app, identifier: "\(identifier).frame")
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
    let clampedOffset = CGVector(
      dx: min(max(normalizedOffset.dx, 0), 1),
      dy: min(max(normalizedOffset.dy, 0), 1)
    )
    let targetPoint = CGPoint(
      x: targetFrame.minX + (targetFrame.width * clampedOffset.dx),
      y: targetFrame.minY + (targetFrame.height * clampedOffset.dy)
    )
    guard !targetPoint.x.isNaN, !targetPoint.y.isNaN else {
      return nil
    }

    recordCoordinateResolution(
      in: app,
      element: frameMarker,
      context: CoordinateResolutionContext(
        source: "frame-marker-center",
        origin: "window",
        containingWindow: containingWindow,
        targetFrame: targetFrame,
        visibleFrame: visibleFrame,
        targetPoint: targetPoint
      )
    )
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
    recordCoordinateResolution(
      in: app,
      element: element,
      context: CoordinateResolutionContext(
        source: "window-clamped-center",
        origin: "window",
        containingWindow: containingWindow,
        targetFrame: targetFrame,
        visibleFrame: visibleFrame,
        targetPoint: targetPoint
      )
    )
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

  private func recordCoordinateResolution(
    in app: XCUIApplication,
    element: XCUIElement,
    context: CoordinateResolutionContext
  ) {
    var details: [String: String] = [
      "source": context.source,
      "origin": context.origin,
      "element_identifier": element.identifier,
      "element_label": element.label,
      "element_type": String(describing: element.elementType),
      "element_frame": frameSummary(element.frame),
      "target_frame": frameSummary(context.targetFrame),
      "visible_frame": frameSummary(context.visibleFrame),
      "target_point": pointSummary(context.targetPoint),
      "window_identifier": context.containingWindow.identifier,
      "window_frame": frameSummary(context.containingWindow.frame),
    ]
    if !context.containingWindow.label.isEmpty {
      details["window_label"] = context.containingWindow.label
    }
    recordDiagnosticsTrace(
      component: "ui-tap",
      event: "coordinate.resolve",
      app: app,
      details: details
    )
  }

  private func frameSummary(_ frame: CGRect) -> String {
    String(
      format: "x=%.1f y=%.1f w=%.1f h=%.1f",
      frame.origin.x,
      frame.origin.y,
      frame.size.width,
      frame.size.height
    )
  }

  private func pointSummary(_ point: CGPoint) -> String {
    String(format: "x=%.1f y=%.1f", point.x, point.y)
  }
}
