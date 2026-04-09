import XCTest

extension HarnessMonitorUITestCase {
  func previewSessionTrigger(in app: XCUIApplication) -> XCUIElement {
    sessionTrigger(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func sessionTrigger(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let identifiedButton = button(in: app, identifier: identifier)
    if identifiedButton.exists {
      return identifiedButton
    }

    let cell = app.cells.matching(identifier: identifier).firstMatch
    if cell.exists {
      return cell
    }

    return element(in: app, identifier: identifier)
  }

  func focusChip(in app: XCUIApplication, identifier: String, title: String) -> XCUIElement {
    let identifiedElement = element(in: app, identifier: identifier)
    return identifiedElement.exists ? identifiedElement : button(in: app, title: title)
  }

  func mainWindow(in app: XCUIApplication) -> XCUIElement {
    let mainWindow = app.windows.matching(identifier: "main").firstMatch
    return mainWindow.exists ? mainWindow : app.windows.firstMatch
  }

  func window(in app: XCUIApplication, containing element: XCUIElement) -> XCUIElement {
    let windows = app.windows.allElementsBoundByIndex.filter(\.exists)
    if let matchingWindow = windows.filter({ $0.frame.contains(element.frame) }).min(by: {
      ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
    }) {
      return matchingWindow
    }
    return mainWindow(in: app)
  }

  func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
    if identifier == HarnessMonitorUITestAccessibility.sidebarSearchField {
      let windowSearchField = mainWindow(in: app).searchFields.firstMatch
      if windowSearchField.exists {
        return windowSearchField
      }
      return app.searchFields.firstMatch
    }

    return app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }

  func button(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let roles: [XCUIElement.ElementType] = [
      .button,
      .menuButton,
      .radioButton,
      .cell,
    ]

    for role in roles {
      let mainWindowMatch = mainWindow(in: app)
        .descendants(matching: role)
        .matching(identifier: identifier)
        .firstMatch
      if mainWindowMatch.exists {
        return mainWindowMatch
      }

      let appMatch = app.descendants(matching: role)
        .matching(identifier: identifier)
        .firstMatch
      if appMatch.exists {
        return appMatch
      }
    }

    return app.buttons.matching(identifier: identifier).firstMatch
  }

  func button(in app: XCUIApplication, title: String) -> XCUIElement {
    let predicate = NSPredicate(format: "label == %@", title)

    let roles: [XCUIElement.ElementType] = [
      .button,
      .radioButton,
      .cell,
    ]

    for role in roles {
      let mainWindowMatch = mainWindow(in: app)
        .descendants(matching: role)
        .matching(predicate)
        .firstMatch
      if mainWindowMatch.exists {
        return mainWindowMatch
      }

      let appMatch = app.descendants(matching: role)
        .matching(predicate)
        .firstMatch
      if appMatch.exists {
        return appMatch
      }
    }

    return app.descendants(matching: .any)
      .matching(predicate)
      .firstMatch
  }

  func sidebarSectionElement(
    in app: XCUIApplication,
    title: String,
    within window: XCUIElement
  ) -> XCUIElement {
    let predicate = NSPredicate(format: "label == %@", title)
    let sidebarMaxX = window.frame.minX + (window.frame.width * 0.4)
    let candidates = app.descendants(matching: .any)
      .matching(predicate)
      .allElementsBoundByIndex
      .filter { element in
        let frame = element.frame
        return
          element.exists
          && frame.width > 20
          && frame.height > 20
          && frame.width < window.frame.width * 0.4
          && frame.height < 80
          && frame.minY > window.frame.minY + 40
          && frame.maxX <= sidebarMaxX
      }

    if let section = candidates.min(by: { $0.frame.minY < $1.frame.minY }) {
      return section
    }

    return app.descendants(matching: .any)
      .matching(predicate)
      .firstMatch
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

  func editableField(in app: XCUIApplication, identifier: String) -> XCUIElement {
    if identifier == HarnessMonitorUITestAccessibility.sidebarSearchField {
      return element(in: app, identifier: identifier)
    }

    let textField = app.textFields.matching(identifier: identifier).firstMatch
    if textField.exists {
      return textField
    }

    let textView = app.textViews.matching(identifier: identifier).firstMatch
    if textView.exists {
      return textView
    }

    return app.descendants(matching: .textField).matching(identifier: identifier).firstMatch
  }

  func toolbarButton(in app: XCUIApplication, index: Int) -> XCUIElement {
    let windowToolbarButtons = mainWindow(in: app).toolbars.buttons
    return
      windowToolbarButtons.count > index
      ? windowToolbarButtons.element(boundBy: index)
      : app.toolbars.buttons.element(boundBy: index)
  }

  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let toolbarButtons = mainWindow(in: app).toolbars.buttons.allElementsBoundByIndex
    if let button = toolbarButtons.first(where: { button in
      let identifier = button.identifier
      return identifier != HarnessMonitorUITestAccessibility.refreshButton
    }) {
      return button
    }

    return toolbarButton(in: app, index: 0)
  }
}
