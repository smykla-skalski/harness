import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
protocol AgentsWindowUITestSupporting: AnyObject {}

@MainActor
extension AgentsWindowUITestSupporting where Self: HarnessMonitorUITestCase {
  func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = [
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"
    ]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  func openAgentsWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton, label: "agents")
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentTuiLaunchPane),
        timeout: Self.actionTimeout
      )
    )
  }

  func reopenAgentsWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton, label: "agents")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func closeAgentsWindow(in app: XCUIApplication) {
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          && !self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func startAgentTui(
    in app: XCUIApplication,
    runtimeTitle: String,
    prompt: String
  ) {
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    if !waitForElement(launchPane, timeout: Self.fastPollInterval) {
      tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
      let state = element(in: app, identifier: Accessibility.agentTuiState)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          launchPane.exists || state.label.contains("selection=create")
        }
      )
    }

    _ = runtimeTitle
    _ = prompt
    app.activate()
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func revealAgentsLaunchAction(in app: XCUIApplication, identifier: String) {
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    var launchAction = button(in: app, identifier: identifier)
    XCTAssertTrue(waitForElement(launchAction, timeout: Self.actionTimeout))

    let scrollTarget = agentsLaunchScrollTarget(in: app, launchPane: launchPane)
    for _ in 0..<8 {
      launchAction = button(in: app, identifier: identifier)
      if launchActionIsVisible(
        in: app,
        scrollTarget: scrollTarget,
        launchAction: launchAction,
        identifier: identifier
      ) {
        return
      }

      dragUp(in: app, element: scrollTarget, distanceRatio: 0.18)
      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }

    XCTFail("Failed to reveal launch action \(identifier)")
  }

  private func launchActionIsVisible(
    in app: XCUIApplication,
    scrollTarget: XCUIElement,
    launchAction: XCUIElement,
    identifier: String
  ) -> Bool {
    if launchAction.exists && launchAction.isHittable {
      return true
    }

    let frameMarker = element(in: app, identifier: "\(identifier).frame")
    guard frameMarker.exists, !frameMarker.frame.isEmpty else {
      return false
    }

    let windowFrame = mainWindow(in: app).frame
    let visibleFrame = scrollTarget.frame.intersection(windowFrame)
    guard !visibleFrame.isNull, !visibleFrame.isEmpty else {
      return false
    }

    let minimumVisibleHeight = min(24, max(frameMarker.frame.height / 2, 1))
    return visibleFrame.height >= minimumVisibleHeight
  }

  private func agentsLaunchScrollTarget(
    in app: XCUIApplication,
    launchPane: XCUIElement
  ) -> XCUIElement {
    let launchWindow = window(in: app, containing: launchPane)
    let nestedScrollViews = launchPane.descendants(matching: .scrollView)

    if let scrollView = visibleLargestScrollTarget(in: nestedScrollViews, window: launchWindow) {
      return scrollView
    }

    if let scrollView = overlappingDetailScrollTarget(
      in: launchWindow.descendants(matching: .scrollView),
      window: launchWindow,
      container: launchPane
    ) {
      return scrollView
    }

    if let scrollView = overlappingDetailScrollTarget(
      in: app.descendants(matching: .scrollView),
      window: launchWindow,
      container: launchPane
    ) {
      return scrollView
    }
    if let largest = visibleLargestScrollTarget(
      in: launchWindow.descendants(matching: .scrollView),
      window: launchWindow
    ) {
      return largest
    }
    if let largest = visibleLargestScrollTarget(
      in: app.descendants(matching: .scrollView),
      window: launchWindow
    ) {
      return largest
    }
    return launchPane
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

  private func visibleLargestScrollTarget(
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

  private func overlappingDetailScrollTarget(
    in query: XCUIElementQuery,
    window: XCUIElement,
    container: XCUIElement
  ) -> XCUIElement? {
    guard container.exists, !container.frame.isEmpty else { return nil }

    let containerFrame = container.frame
    let containerMidX = containerFrame.midX
    let windowMidX = window.frame.midX
    let candidates = query.allElementsBoundByIndex.filter { candidate in
      guard candidate.exists, !candidate.frame.isEmpty else { return false }
      let candidateFrame = candidate.frame
      let visibleFrame = candidateFrame.intersection(window.frame)
      let overlapsContainerHorizontally =
        candidateFrame.minX <= containerFrame.maxX
        && containerFrame.minX <= candidateFrame.maxX
      let overlapsContainerVertically =
        candidateFrame.minY <= containerFrame.maxY
        && containerFrame.minY <= candidateFrame.maxY
      return
        candidateFrame.minX <= containerMidX
        && containerMidX <= candidateFrame.maxX
        && overlapsContainerHorizontally
        && overlapsContainerVertically
        && !visibleFrame.isNull
        && !visibleFrame.isEmpty
    }

    let detailCandidates = candidates.filter { candidate in
      candidate.frame.midX > windowMidX
    }

    let preferredCandidates = detailCandidates.isEmpty ? candidates : detailCandidates
    return preferredCandidates.max { left, right in
      left.frame.width * left.frame.height < right.frame.width * right.frame.height
    }
  }

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
    let filterButton = button(in: app, identifier: Accessibility.agentsDecisionFiltersMenu)
    XCTAssertTrue(
      waitForElement(filterButton, timeout: Self.fastActionTimeout),
      "Agents window decision filter menu should exist before opening it"
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
    let filterState = element(in: app, identifier: Accessibility.agentsDecisionFilterState)
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.fastActionTimeout),
      "Agents window decision filter state should exist before resetting severities"
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
