import XCTest

extension HarnessMonitorUITestCase {
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
    clickMenuElement(menuBarItem, in: app, failureMessage: "Failed to open the \(menuTitle) menu")

    let menuItem = menuBarItem.menuItems[title].firstMatch
    XCTAssertTrue(
      waitForElement(menuItem, timeout: Self.actionTimeout),
      "\(title) menu item should appear after opening the \(menuTitle) menu"
    )
    clickMenuElement(
      menuItem,
      in: app,
      failureMessage: "Failed to activate the \(title) item in the \(menuTitle) menu"
    )
  }

  func invokeNestedMenuItem(
    in app: XCUIApplication,
    menu menuTitle: String,
    submenu submenuTitle: String,
    title: String
  ) {
    app.activate()
    let menuBarItem = app.menuBars.menuBarItems[menuTitle].firstMatch
    XCTAssertTrue(
      waitForElement(menuBarItem, timeout: Self.actionTimeout),
      "\(menuTitle) menu should exist in the menu bar"
    )
    clickMenuElement(menuBarItem, in: app, failureMessage: "Failed to open the \(menuTitle) menu")

    let submenuItem = menuBarItem.menuItems[submenuTitle].firstMatch
    XCTAssertTrue(
      waitForElement(submenuItem, timeout: Self.actionTimeout),
      "\(submenuTitle) submenu should appear after opening the \(menuTitle) menu"
    )
    clickMenuElement(
      submenuItem,
      in: app,
      failureMessage: "Failed to open the \(submenuTitle) submenu in the \(menuTitle) menu"
    )

    let menuItem = submenuItem.menuItems[title].firstMatch
    XCTAssertTrue(
      waitForElement(menuItem, timeout: Self.actionTimeout),
      "\(title) menu item should appear after opening the \(submenuTitle) submenu"
    )
    clickMenuElement(
      menuItem,
      in: app,
      failureMessage: "Failed to activate the \(title) item in the \(submenuTitle) submenu"
    )
  }

  private func clickMenuElement(
    _ element: XCUIElement,
    in app: XCUIApplication,
    failureMessage: String
  ) {
    if let coordinate = preferredTapCoordinate(in: app, for: element) {
      coordinate.click()
      return
    }
    if element.isHittable {
      element.click()
      return
    }
    XCTFail(failureMessage)
  }
}
