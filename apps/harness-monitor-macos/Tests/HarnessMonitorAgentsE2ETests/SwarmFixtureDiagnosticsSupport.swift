import Foundation
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension SwarmFixture {
  func expectIdentifier(_ identifier: String, timeout: TimeInterval = 15) {
    let element = testCase.element(in: app, identifier: identifier)
    trace(
      "expect-identifier.begin",
      app: app,
      details: [
        "identifier": identifier,
        "timeout_seconds": String(timeout),
      ]
    )
    let exists = testCase.waitForElement(element, timeout: timeout)
    if !exists {
      trace(
        "expect-identifier.timeout",
        app: app,
        details: [
          "identifier": identifier,
          "timeout_seconds": String(timeout),
        ]
      )
    }
    XCTAssertTrue(
      exists,
      "Expected identifier \(identifier)\n\(diagnosticsSummary())"
    )
    if exists {
      trace(
        "expect-identifier.success",
        app: app,
        details: [
          "identifier": identifier,
          "label": element.label,
        ]
      )
    }
  }

  func expectIdentifier(_ identifier: String, labelContains expectedText: String) {
    let element = testCase.element(in: app, identifier: identifier)
    trace(
      "expect-identifier-label.begin",
      app: app,
      details: [
        "identifier": identifier,
        "expected_text": expectedText,
      ]
    )
    let matches = testCase.waitUntil(timeout: 15) {
      element.exists && element.label.contains(expectedText)
    }
    if !matches {
      trace(
        "expect-identifier-label.timeout",
        app: app,
        details: [
          "identifier": identifier,
          "expected_text": expectedText,
          "actual_label": element.label,
        ]
      )
    }
    XCTAssertTrue(
      matches,
      """
      Expected identifier \(identifier) label to contain \(expectedText).
      actualLabel=\(element.label)
      \(diagnosticsSummary())
      """
    )
    if matches {
      trace(
        "expect-identifier-label.success",
        app: app,
        details: [
          "identifier": identifier,
          "label": element.label,
          "expected_text": expectedText,
        ]
      )
    }
  }

  func expectAnyIdentifier(_ identifiers: [String], timeout: TimeInterval = 15) {
    trace(
      "expect-any-identifier.begin",
      app: app,
      details: [
        "identifiers": identifiers.joined(separator: ","),
        "timeout_seconds": String(timeout),
      ]
    )
    let exists = testCase.waitUntil(timeout: timeout) {
      identifiers.contains { self.testCase.element(in: self.app, identifier: $0).exists }
    }
    if !exists {
      trace(
        "expect-any-identifier.timeout",
        app: app,
        details: [
          "identifiers": identifiers.joined(separator: ","),
          "timeout_seconds": String(timeout),
        ]
      )
    }
    XCTAssertTrue(
      exists,
      "Expected one of \(identifiers.joined(separator: ", "))\n\(diagnosticsSummary())"
    )
    if exists {
      trace(
        "expect-any-identifier.success",
        app: app,
        details: ["identifiers": identifiers.joined(separator: ",")]
      )
    }
  }

  func diagnosticsSummary() -> String {
    var lines = [
      "stateRoot=\(stateRootURL.path)",
      "dataHome=\(dataHomeURL.path)",
      "sessionID=\(sessionID)",
      "daemonLog=\(daemonLogPath)",
      "syncDir=\(syncDirURL.path)",
    ]
    if let tracePath = diagnosticsTraceFileURL(
      for: HarnessMonitorUITestCase.artifactsDirectoryKey
    )?.path {
      lines.append("uiTrace=\(tracePath)")
    }
    return lines.joined(separator: "\n")
  }

  func trace(
    _ event: String,
    app: XCUIApplication? = nil,
    details: [String: String] = [:]
  ) {
    testCase.recordDiagnosticsTrace(
      component: "swarm",
      event: event,
      app: app,
      details: details
    )
  }

  func frameSummary(_ frame: CGRect) -> String {
    String(
      format: "x=%.1f y=%.1f w=%.1f h=%.1f",
      frame.origin.x,
      frame.origin.y,
      frame.size.width,
      frame.size.height
    )
  }

  func scrollElementIntoView(
    _ element: XCUIElement,
    timeout: TimeInterval = 8
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }
      if element.exists && (element.isHittable || elementIsVisibleInScrollTarget(element)) {
        return true
      }

      scrollToward(element)
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))
    }
    return element.exists && (element.isHittable || elementIsVisibleInScrollTarget(element))
  }

  func scrollSessionTaskIntoView(
    _ element: XCUIElement,
    timeout: TimeInterval = 12
  ) -> Bool {
    let target = sessionTaskScrollView(for: element)
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if app.state != .runningForeground {
        app.activate()
      }
      if element.exists && (element.isHittable || elementIsVisibleInContainer(element, target)) {
        return true
      }

      scrollSessionTaskList(target, toward: element)
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.15))
    }
    return element.exists && (element.isHittable || elementIsVisibleInContainer(element, target))
  }

  func taskActionsSheetIsPresented() -> Bool {
    let sheet = testCase.element(in: app, identifier: Accessibility.taskActionsSheet)
    if sheet.exists {
      return true
    }

    let dismissButton = testCase.element(
      in: app,
      identifier: Accessibility.taskActionsSheetDismiss
    )
    return dismissButton.exists
  }

  func scrollTarget(for element: XCUIElement) -> XCUIElement {
    let window = testCase.mainWindow(in: app)
    if let scrollView = matchingScrollTarget(in: window.scrollViews, for: element) {
      return scrollView
    }
    if let scrollView = matchingScrollTarget(in: app.scrollViews, for: element) {
      return scrollView
    }

    if let largest = largestScrollTarget(in: window.scrollViews) {
      return largest
    }
    if let largest = largestScrollTarget(in: app.scrollViews) {
      return largest
    }
    return window
  }

  func sessionTaskScrollView(for element: XCUIElement) -> XCUIElement {
    let cockpitWindow = sessionCockpitWindow()
    if let scrollView = matchingSessionTaskScrollView(in: cockpitWindow.scrollViews, task: element)
    {
      return scrollView
    }
    if let scrollView = matchingScrollTarget(in: cockpitWindow.scrollViews, for: element) {
      return scrollView
    }
    if let scrollView = matchingSessionTaskScrollView(in: app.scrollViews, task: element) {
      return scrollView
    }
    return scrollTarget(for: element)
  }

  private func elementIsVisibleInScrollTarget(_ element: XCUIElement) -> Bool {
    guard element.exists, !element.frame.isEmpty else { return false }

    let targetFrame = scrollTarget(for: element).frame
    let windowFrame = testCase.mainWindow(in: app).frame
    let visibleFrame = targetFrame.intersection(windowFrame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else { return false }

    return visibleFrame.insetBy(dx: -1, dy: -1)
      .contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
  }

  private func elementIsVisibleInContainer(
    _ element: XCUIElement,
    _ container: XCUIElement
  ) -> Bool {
    guard
      element.exists,
      !element.frame.isEmpty,
      container.exists,
      !container.frame.isEmpty
    else {
      return false
    }

    let visibleFrame = element.frame.intersection(container.frame)
    return !visibleFrame.isNull && !visibleFrame.isEmpty
  }

  private func scrollToward(_ element: XCUIElement) {
    let target = scrollTarget(for: element)
    guard target.exists else { return }
    let window = testCase.mainWindow(in: app)
    let shouldScrollUp =
      !(element.exists
      && !element.frame.isEmpty
      && !window.frame.isEmpty
      && element.frame.minY < window.frame.minY + 72)
    let magnitude = max(240, target.frame.height * 0.9)
    let delta: CGFloat = shouldScrollUp ? -magnitude : magnitude
    target.scroll(byDeltaX: 0, deltaY: delta)
  }

  private func scrollSessionTaskList(
    _ target: XCUIElement,
    toward element: XCUIElement
  ) {
    guard target.exists, !target.frame.isEmpty else { return }

    let magnitude = max(240, target.frame.height * 0.85)
    let delta: CGFloat
    if element.exists, !element.frame.isEmpty, element.frame.minY < target.frame.minY + 32 {
      delta = magnitude
    } else {
      delta = -magnitude
    }
    target.scroll(byDeltaX: 0, deltaY: delta)
  }

  private func largestScrollTarget(in query: XCUIElementQuery) -> XCUIElement? {
    let searchCount = min(query.count, 12)
    var bestArea: CGFloat = 0
    var bestMatch: XCUIElement?
    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }
      let area = candidate.frame.width * candidate.frame.height
      if area > bestArea {
        bestArea = area
        bestMatch = candidate
      }
    }
    return bestMatch
  }

  private func matchingScrollTarget(
    in query: XCUIElementQuery,
    for element: XCUIElement
  ) -> XCUIElement? {
    guard element.exists, !element.frame.isEmpty else { return nil }

    let elementFrame = element.frame
    let elementMidX = elementFrame.midX
    let searchCount = min(query.count, 12)
    var bestOverlap: CGFloat = 0
    var bestMatch: XCUIElement?

    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }

      let candidateFrame = candidate.frame
      if candidateFrame.minX <= elementMidX, elementMidX <= candidateFrame.maxX {
        return candidate
      }

      let horizontalOverlap =
        min(candidateFrame.maxX, elementFrame.maxX) - max(candidateFrame.minX, elementFrame.minX)
      if horizontalOverlap > bestOverlap {
        bestOverlap = horizontalOverlap
        bestMatch = candidate
      }
    }

    return bestMatch
  }

  private func matchingSessionTaskScrollView(
    in query: XCUIElementQuery,
    task: XCUIElement
  ) -> XCUIElement? {
    let taskIdentifier = task.identifier
    let searchCount = min(query.count, 12)
    var fallback: XCUIElement?

    for index in 0..<searchCount {
      let candidate = query.element(boundBy: index)
      guard candidate.exists, !candidate.frame.isEmpty else { continue }

      let stateMarker = candidate.descendants(matching: .any)
        .matching(identifier: Accessibility.sessionTaskListState)
        .firstMatch
      if stateMarker.exists {
        return candidate
      }

      if !taskIdentifier.isEmpty {
        let taskMatch = candidate.descendants(matching: .any)
          .matching(identifier: taskIdentifier)
          .firstMatch
        if taskMatch.exists, fallback == nil {
          fallback = candidate
        }
      }
    }

    return fallback
  }

  private func sessionCockpitWindow() -> XCUIElement {
    let taskListState = testCase.element(in: app, identifier: Accessibility.sessionTaskListState)
    if taskListState.exists {
      return testCase.window(in: app, containing: taskListState)
    }

    let appChrome = testCase.element(in: app, identifier: Accessibility.appChromeRoot)
    if appChrome.exists {
      return testCase.window(in: app, containing: appChrome)
    }

    return testCase.mainWindow(in: app)
  }
}
