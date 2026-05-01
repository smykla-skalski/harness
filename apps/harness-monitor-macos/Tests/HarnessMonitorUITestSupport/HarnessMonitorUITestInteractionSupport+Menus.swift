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
    menuBarItem.click()

    let menuItem = app.menuItems[title].firstMatch
    XCTAssertTrue(
      waitForElement(menuItem, timeout: Self.actionTimeout),
      "\(title) menu item should appear after opening the \(menuTitle) menu"
    )
    menuItem.click()
  }
}
