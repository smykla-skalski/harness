import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension AgentTuiWindowUITests {
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

  func openAgentTuiWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton, label: "agents")
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentTuiLaunchPane),
        timeout: Self.actionTimeout
      )
    )
  }

  func reopenAgentTuiWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton, label: "agents")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func closeAgentTuiWindow(in app: XCUIApplication) {
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          && !self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func invokeHarnessMonitorMenuItem(
    in app: XCUIApplication,
    title: String
  ) {
    app.activate()
    let commandMenu = app.menuBars.menuBarItems["Harness Monitor"].firstMatch
    XCTAssertTrue(
      waitForElement(commandMenu, timeout: Self.actionTimeout),
      "Harness Monitor menu should exist"
    )
    commandMenu.click()

    let menuItem = app.menuItems[title].firstMatch
    XCTAssertTrue(
      waitForElement(menuItem, timeout: Self.actionTimeout),
      "\(title) menu item should appear after opening the Harness Monitor menu"
    )
    menuItem.click()
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

  func tapDockButton(
    in app: XCUIApplication,
    identifier: String,
    label: String
  ) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      },
      "\(label) dock button should be visible in cockpit preview"
    )
    if trigger.isHittable {
      trigger.tap()
    } else if let coordinate = centerCoordinate(in: app, for: trigger) {
      coordinate.tap()
    } else {
      XCTFail("Cannot resolve coordinate for \(label) dock button")
    }
  }

  func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard let coordinate = centerCoordinate(in: app, for: element) else {
      XCTFail("Failed to resolve coordinate for \(element)")
      return
    }
    coordinate.tap()
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
}
