import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension WorkspaceWindowUITestSupporting where Self: HarnessMonitorUITestCase {
  func tapDockButton(
    in app: XCUIApplication,
    identifier: String,
    label: String
  ) {
    app.activate()
    XCTAssertTrue(
      waitForButtonReady(in: app, identifier: identifier, timeout: Self.actionTimeout),
      "\(label) dock button should be visible in cockpit preview"
    )
    tapButton(in: app, identifier: identifier)
  }

  func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard tapElementReliably(in: app, element: element) else {
      XCTFail("Failed to resolve coordinate for \(element)")
      return
    }
  }

  func openAgentsDecisionFilters(in app: XCUIApplication) {
    let filterButton = button(in: app, identifier: Accessibility.workspaceDecisionFiltersMenu)
    XCTAssertTrue(
      waitForElement(filterButton, timeout: Self.fastActionTimeout),
      "Workspace window decision filter menu should exist before opening it"
    )

    app.activate()
    if let coordinate = centerCoordinate(in: app, for: filterButton) {
      coordinate.click()
    } else if filterButton.isHittable {
      filterButton.click()
    } else {
      XCTFail("Failed to resolve the actual agents decision filter control")
      return
    }

    XCTAssertTrue(
      waitForElement(element(in: app, title: "Critical"), timeout: Self.fastActionTimeout),
      "Agents decision filter menu should present the severity filter commands"
    )
  }

  func resetAgentsDecisionSeveritiesIfNeeded(in app: XCUIApplication) {
    let filterState = element(in: app, identifier: Accessibility.workspaceDecisionFilterState)
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.fastActionTimeout),
      "Workspace window decision filter state should exist before resetting severities"
    )
    guard !filterState.label.contains("severities=all") else {
      return
    }

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "All severities")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=all")
      },
      """
      Resetting the agents decision severity menu should restore the full severity set \
      before the test continues.
      state=\(filterState.label)
      """
    )
  }

  func agentTuiActionExists(
    in app: XCUIApplication,
    title: String,
    identifier: String
  ) -> Bool {
    button(in: app, identifier: identifier).exists
      || element(in: app, identifier: identifier).exists
      || element(in: app, identifier: "\(identifier).frame").exists
      || button(in: app, title: title).exists
      || element(in: app, title: title).exists
  }

  func dragViewportDivider(
    in app: XCUIApplication,
    viewport: XCUIElement,
    controls: XCUIElement,
    verticalOffset: CGFloat
  ) {
    let window = window(in: app, containing: viewport)
    XCTAssertTrue(waitForElement(window, timeout: Self.fastActionTimeout))

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let start = origin.withOffset(
      CGVector(
        dx: viewport.frame.midX - window.frame.minX,
        dy: controls.frame.minY - window.frame.minY - 2
      )
    )
    let end = start.withOffset(CGVector(dx: 0, dy: verticalOffset))
    start.press(forDuration: 0.01, thenDragTo: end)
  }

  func agentTuiSize(from label: String) -> (rows: Int, cols: Int)? {
    guard let markerRange = label.range(of: "size=") else {
      return nil
    }
    let sizeText = label[markerRange.upperBound...]
      .split(separator: ",", maxSplits: 1)
      .first
    guard let sizeText else {
      return nil
    }
    let components = sizeText.split(separator: "x", maxSplits: 1)
    guard components.count == 2,
      let rows = Int(components[0]),
      let cols = Int(components[1])
    else {
      return nil
    }
    return (rows, cols)
  }

  func agentTuiViewportContainsText(
    in app: XCUIApplication,
    text: String
  ) -> Bool {
    let viewport = element(in: app, identifier: Accessibility.agentTuiViewport)
    if viewport.label.contains(text) {
      return true
    }
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return viewport.staticTexts.matching(predicate).firstMatch.exists
      || app.staticTexts.matching(predicate).firstMatch.exists
  }
}
