import XCTest

extension HarnessMonitorUITestCase {
  func selectMenuOption(in app: XCUIApplication, controlIdentifier: String, optionTitle: String) {
    let control = popUpButton(in: app, identifier: controlIdentifier)
    XCTAssertTrue(
      control.exists || control.waitForExistence(timeout: Self.fastActionTimeout)
    )

    app.activate()
    if control.isHittable {
      control.tap()
    } else if !control.frame.isEmpty,
      let coordinate = centerCoordinate(in: app, for: control)
    {
      coordinate.tap()
    } else {
      let frameMarker = frameElement(in: app, identifier: "\(controlIdentifier).frame")
      guard frameMarker.waitForExistence(timeout: Self.fastActionTimeout),
        let coordinate = centerCoordinate(in: app, for: frameMarker)
      else {
        XCTFail("Failed to open pop-up button \(controlIdentifier)")
        return
      }
      coordinate.tap()
    }

    let menuItem = presentedMenuOption(in: app, title: optionTitle)
    XCTAssertTrue(
      menuItem.exists || menuItem.waitForExistence(timeout: Self.fastActionTimeout)
    )

    if menuItem.isHittable {
      menuItem.tap()
    } else {
      let frameMarker = frameElement(in: app, identifier: "\(optionTitle).frame")
      if let coordinate = centerCoordinate(in: app, for: menuItem) {
        coordinate.tap()
      } else if (frameMarker.exists || frameMarker.waitForExistence(timeout: Self.fastActionTimeout)),
        let coordinate = centerCoordinate(in: app, for: frameMarker)
      {
        coordinate.tap()
      } else {
        XCTFail("Failed to select menu option \(optionTitle)")
      }
    }
  }

  func element(in app: XCUIApplication, title: String) -> XCUIElement {
    nativePresentationElement(in: app, title: title)
  }

  func confirmationDialogButton(in app: XCUIApplication, title: String) -> XCUIElement {
    nativePresentationElement(in: app, title: title)
  }

  func dismissConfirmationDialog(in app: XCUIApplication) {
    let cancelButton = confirmationDialogButton(in: app, title: "Cancel")
    XCTAssertTrue(cancelButton.waitForExistence(timeout: Self.actionTimeout))
    cancelButton.tap()
  }

  func popUpButton(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let appMatch = app.popUpButtons.matching(identifier: identifier).firstMatch
    if appMatch.exists {
      return appMatch
    }

    let descendantMatch = app.descendants(matching: .popUpButton)
      .matching(identifier: identifier)
      .firstMatch
    if descendantMatch.exists {
      return descendantMatch
    }

    let genericMatch = element(in: app, identifier: identifier)
    if genericMatch.exists {
      return genericMatch
    }

    return button(in: app, identifier: identifier)
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

  private func presentedMenuOption(in app: XCUIApplication, title: String) -> XCUIElement {
    let predicate = NSPredicate(
      format: "label == %@ OR title == %@ OR identifier == %@",
      title,
      title,
      title
    )

    let candidateQueries: [XCUIElementQuery] = [
      app.menus.descendants(matching: .menuItem).matching(predicate),
      app.menus.descendants(matching: .button).matching(predicate),
      app.menus.descendants(matching: .staticText).matching(predicate),
      app.descendants(matching: .menuItem).matching(predicate),
      app.descendants(matching: .button).matching(predicate),
      app.descendants(matching: .staticText).matching(predicate),
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
