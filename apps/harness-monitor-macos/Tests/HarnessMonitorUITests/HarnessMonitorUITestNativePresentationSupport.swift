import XCTest

extension HarnessMonitorUITestCase {
  func element(in app: XCUIApplication, title: String) -> XCUIElement {
    nativePresentationElement(in: app, title: title)
  }

  func confirmationDialogButton(in app: XCUIApplication, title: String) -> XCUIElement {
    nativePresentationElement(in: app, title: title)
  }

  func dismissConfirmationDialog(in app: XCUIApplication) {
    let cancelButton = confirmationDialogButton(in: app, title: "Cancel")
    XCTAssertTrue(cancelButton.waitForExistence(timeout: Self.uiTimeout))
    cancelButton.tap()
  }

  private func nativePresentationElement(
    in app: XCUIApplication,
    title: String
  ) -> XCUIElement {
    // macOS confirmation dialogs can surface as sheets, dialogs, or menu-like
    // action presentations. The actionable items are consistently exposed, but
    // the title text is not guaranteed to be a separate accessibility node.
    let predicate = NSPredicate(
      format: "label == %@ OR title == %@ OR identifier == %@",
      title,
      title,
      title
    )

    let candidateQueries: [XCUIElementQuery] = [
      app.sheets.descendants(matching: .any).matching(predicate),
      app.dialogs.descendants(matching: .any).matching(predicate),
      app.descendants(matching: .menuItem).matching(predicate),
      app.descendants(matching: .button).matching(predicate),
      app.descendants(matching: .any).matching(predicate),
    ]

    for query in candidateQueries {
      let element = query.firstMatch
      if element.exists {
        return element
      }
    }

    return candidateQueries.last!.firstMatch
  }
}
