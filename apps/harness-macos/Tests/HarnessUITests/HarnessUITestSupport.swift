import XCTest

@MainActor
class HarnessUITestCase: XCTestCase {
  static let launchModeKey = "HARNESS_LAUNCH_MODE"
  static let uiTestHostBundleIdentifier = "io.aiharness.app.ui-testing"
  static let uiTimeout: TimeInterval = 10

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDown() async throws {
    await MainActor.run {
      let app = XCUIApplication(
        bundleIdentifier: Self.uiTestHostBundleIdentifier
      )
      terminateIfRunning(app)
    }
  }
}

extension HarnessUITestCase {
  func mainWindow(in app: XCUIApplication) -> XCUIElement {
    let mainWindow = app.windows.matching(identifier: "main").firstMatch
    if mainWindow.exists {
      return mainWindow
    }
    return app.windows.firstMatch
  }

  func window(in app: XCUIApplication, containing element: XCUIElement) -> XCUIElement {
    let windows = app.windows.allElementsBoundByIndex.filter(\.exists)
    if let matchingWindow = windows.first(where: { $0.frame.contains(element.frame) }) {
      return matchingWindow
    }
    return mainWindow(in: app)
  }

  func launch(mode: String) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment["HARNESS_UI_TESTS"] = "1"
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launch()
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }

        return app.state == .runningForeground || self.mainWindow(in: app).exists
      }
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        let window = self.mainWindow(in: app)
        app.activate()
        return
          window.exists
          && window.frame.width > 0
          && window.frame.height > 0
      }
    )
    return app
  }

  func terminateIfRunning(_ app: XCUIApplication) {
    switch app.state {
    case .runningForeground, .runningBackground:
      app.terminate()
      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
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
    let deadline = Date.now.addingTimeInterval(Self.uiTimeout)

    while Date.now < deadline {
      app.activate()

      let button = button(in: app, identifier: identifier)
      if button.waitForExistence(timeout: 0.5) {
        if button.isHittable {
          button.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: button) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap button \(identifier)")
  }

  func tapElement(in app: XCUIApplication, identifier: String) {
    let deadline = Date.now.addingTimeInterval(Self.uiTimeout)

    while Date.now < deadline {
      app.activate()

      let target = element(in: app, identifier: identifier)
      if target.waitForExistence(timeout: 0.5) {
        if target.isHittable {
          target.tap()
          return
        }

        if let coordinate = centerCoordinate(in: app, for: target) {
          coordinate.tap()
          return
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }

    XCTFail("Failed to tap element \(identifier)")
  }

  func selectMenuOption(
    in app: XCUIApplication,
    controlIdentifier: String,
    optionTitle: String
  ) {
    let control = element(in: app, identifier: controlIdentifier)
    XCTAssertTrue(control.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: controlIdentifier)

    let menuItem = app.descendants(matching: .menuItem).matching(
      NSPredicate(format: "title == %@", optionTitle)
    ).firstMatch
    XCTAssertTrue(menuItem.waitForExistence(timeout: Self.uiTimeout))
    menuItem.tap()
  }

  func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  func button(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let mainWindowButton = mainWindow(in: app)
      .descendants(matching: .button)
      .matching(identifier: identifier)
      .firstMatch
    if mainWindowButton.exists {
      return mainWindowButton
    }
    return app.buttons.matching(identifier: identifier).firstMatch
  }

  func frameElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.otherElements.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let mainWindowToolbarButton = mainWindow(in: app)
      .toolbars
      .buttons
      .matching(identifier: identifier)
      .firstMatch
    if mainWindowToolbarButton.exists {
      return mainWindowToolbarButton
    }
    return app.toolbars.buttons.matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, index: Int) -> XCUIElement {
    let windowToolbarButtons = mainWindow(in: app).toolbars.buttons
    if windowToolbarButtons.count > index {
      return windowToolbarButtons.element(boundBy: index)
    }
    return app.toolbars.buttons.element(boundBy: index)
  }

  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarButtons = mainWindow(in: app).toolbars.buttons.allElementsBoundByIndex
    if let button = toolbarButtons.first(where: { button in
      let identifier = button.identifier
      return
        identifier != HarnessUITestAccessibility.refreshButton
        && identifier != HarnessUITestAccessibility.preferencesButton
    }) {
      return button
    }

    return toolbarButton(in: app, index: 0)
  }

  func dragUp(in app: XCUIApplication, element: XCUIElement, distanceRatio: CGFloat = 0.32) {
    let window = mainWindow(in: app)
    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))

    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let x = element.frame.midX - window.frame.minX
    let startY = element.frame.maxY - window.frame.minY - 36
    let minimumEndY = element.frame.minY - window.frame.minY + 36
    let targetEndY = startY - (element.frame.height * distanceRatio)
    let endY = max(minimumEndY, targetEndY)

    let start = origin.withOffset(CGVector(dx: x, dy: startY))
    let end = origin.withOffset(CGVector(dx: x, dy: endY))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  func confirmationDialogButton(in app: XCUIApplication, title: String) -> XCUIElement {
    let alertButton = app.sheets.buttons[title]
    if alertButton.exists {
      return alertButton
    }
    return app.dialogs.buttons[title]
  }

  func dismissConfirmationDialog(in app: XCUIApplication) {
    let cancelButton = confirmationDialogButton(in: app, title: "Cancel")
    XCTAssertTrue(cancelButton.waitForExistence(timeout: Self.uiTimeout))
    cancelButton.tap()
  }

  func attachWindowScreenshot(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(screenshot: mainWindow(in: app).screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func attachAppHierarchy(
    in app: XCUIApplication,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(string: app.debugDescription)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func waitUntil(
    timeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.1,
    condition: @escaping () -> Bool
  ) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if condition() {
        return true
      }
      RunLoop.current.run(until: Date.now.addingTimeInterval(pollInterval))
    }
    return condition()
  }

  private func centerCoordinate(
    in app: XCUIApplication,
    for element: XCUIElement
  ) -> XCUICoordinate? {
    let window = mainWindow(in: app)
    guard window.waitForExistence(timeout: 0.5) else {
      return nil
    }
    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let dx = element.frame.midX - window.frame.minX
    let dy = element.frame.midY - window.frame.minY
    return origin.withOffset(CGVector(dx: dx, dy: dy))
  }

  func assertFillsColumn(
    child: XCUIElement,
    in container: XCUIElement,
    expectedHorizontalInset: CGFloat,
    tolerance: CGFloat
  ) {
    let expectedWidth = container.frame.width - (expectedHorizontalInset * 2)
    XCTAssertEqual(child.frame.width, expectedWidth, accuracy: tolerance * 2)
    XCTAssertEqual(
      child.frame.minX,
      container.frame.minX + expectedHorizontalInset,
      accuracy: tolerance
    )
    XCTAssertEqual(
      child.frame.maxX,
      container.frame.maxX - expectedHorizontalInset,
      accuracy: tolerance
    )
  }

  func assertSameRow(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.minY, first.frame.minY, accuracy: tolerance)
    }
  }

  func assertEqualHeights(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.height, first.frame.height, accuracy: tolerance)
    }
  }
}
