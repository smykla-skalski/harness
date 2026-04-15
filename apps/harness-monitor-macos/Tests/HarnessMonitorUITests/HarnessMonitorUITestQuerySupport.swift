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
      let roles: [XCUIElement.ElementType] = [
        .textField,
        .searchField,
        .comboBox,
      ]
      for role in roles {
        let windowMatch = mainWindow(in: app)
          .descendants(matching: role)
          .matching(identifier: identifier)
          .firstMatch
        if windowMatch.exists {
          return windowMatch
        }

        let appMatch = app.descendants(matching: role)
          .matching(identifier: identifier)
          .firstMatch
        if appMatch.exists {
          return appMatch
        }
      }

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

  func descendantElement(in container: XCUIElement, identifier: String) -> XCUIElement {
    let candidates = container.descendants(matching: .any)
      .matching(identifier: identifier)
      .allElementsBoundByIndex

    if let candidate = candidates.last(where: { candidate in
      candidate.exists
        && (!candidate.label.isEmpty || !candidate.frame.isEmpty)
    }) {
      return candidate
    }

    return container.descendants(matching: .any)
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

    let roles: [XCUIElement.ElementType] = [
      .button,
      .radioButton,
      .cell,
    ]

    for role in roles {
      let windowMatch = window.descendants(matching: role)
        .matching(predicate)
        .firstMatch
      if windowMatch.exists {
        return windowMatch
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

  func frameElement(in app: XCUIApplication, identifier: String) -> XCUIElement {
    app.otherElements.matching(identifier: identifier).firstMatch
  }

  func descendantFrameElement(in container: XCUIElement, identifier: String) -> XCUIElement {
    let candidates = container.descendants(matching: .any)
      .matching(identifier: identifier)
      .allElementsBoundByIndex

    if let candidate = candidates.last(where: { candidate in
      candidate.exists && !candidate.frame.isEmpty
    }) {
      return candidate
    }

    return container.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
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

  func segmentedControl(in app: XCUIApplication, identifier: String) -> XCUIElement {
    let mainWindowMatch = mainWindow(in: app)
      .descendants(matching: .segmentedControl)
      .matching(identifier: identifier)
      .firstMatch
    if mainWindowMatch.exists {
      return mainWindowMatch
    }

    let appMatch = app.descendants(matching: .segmentedControl)
      .matching(identifier: identifier)
      .firstMatch
    if appMatch.exists {
      return appMatch
    }

    return element(in: app, identifier: identifier)
  }

  func editableField(in app: XCUIApplication, identifier: String) -> XCUIElement {
    if identifier == HarnessMonitorUITestAccessibility.sidebarSearchField {
      return element(in: app, identifier: identifier)
    }

    let mainWindow = mainWindow(in: app)
    let roles: [XCUIElement.ElementType] = [
      .textField,
      .textView,
      .comboBox,
    ]

    for role in roles {
      let windowMatch = mainWindow.descendants(matching: role)
        .matching(identifier: identifier)
        .firstMatch
      if windowMatch.exists {
        return windowMatch
      }

      let appMatch = app.descendants(matching: role)
        .matching(identifier: identifier)
        .firstMatch
      if appMatch.exists {
        return appMatch
      }
    }

    let textField = app.textFields.matching(identifier: identifier).firstMatch
    if textField.exists {
      return textField
    }

    let textView = app.textViews.matching(identifier: identifier).firstMatch
    if textView.exists {
      return textView
    }

    let genericMatch = element(in: app, identifier: identifier)
    if genericMatch.exists {
      return genericMatch
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
