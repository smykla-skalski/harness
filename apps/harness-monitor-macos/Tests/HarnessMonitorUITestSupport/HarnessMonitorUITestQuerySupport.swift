import XCTest

extension HarnessMonitorUITestCase {
  private static var maxWindowSearchCount: Int { 4 }
  private static var maxToolbarButtonSearchCount: Int { 12 }

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
    let primaryWindow = mainWindow(in: app)
    if primaryWindow.exists, primaryWindow.frame.contains(element.frame) {
      return primaryWindow
    }

    let windows = app.windows
    let searchCount = min(windows.count, Self.maxWindowSearchCount)
    var bestMatch: XCUIElement?
    for index in 0..<searchCount {
      let candidate = windows.element(boundBy: index)
      guard candidate.exists, candidate.frame.contains(element.frame) else {
        continue
      }
      guard let currentBest = bestMatch else {
        bestMatch = candidate
        continue
      }
      if candidate.frame.width * candidate.frame.height < currentBest.frame.width * currentBest.frame.height {
        bestMatch = candidate
      }
    }
    if let bestMatch {
      return bestMatch
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
    let match = container.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
    if match.exists {
      return match
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
      .menuButton,
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
    let match = container.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
    if match.exists {
      return match
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

    let genericMatch = element(in: app, identifier: identifier)
    return genericMatch
  }

  func toolbarButton(in app: XCUIApplication, index: Int) -> XCUIElement {
    let windowToolbarButtons = mainWindow(in: app).toolbars.buttons
    return
      windowToolbarButtons.count > index
      ? windowToolbarButtons.element(boundBy: index)
      : app.toolbars.buttons.element(boundBy: index)
  }

  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let excludedIdentifiers: Set<String> = [
      HarnessMonitorUITestAccessibility.navigateBackButton,
      HarnessMonitorUITestAccessibility.navigateForwardButton,
      HarnessMonitorUITestAccessibility.refreshButton,
      HarnessMonitorUITestAccessibility.sleepPreventionButton,
      HarnessMonitorUITestAccessibility.inspectorToggleButton,
      HarnessMonitorUITestAccessibility.sidebarNewSessionButton,
    ]
    let toolbarButtons = mainWindow(in: app).toolbars.buttons
    let searchCount = min(toolbarButtons.count, Self.maxToolbarButtonSearchCount)
    for index in 0..<searchCount {
      let button = toolbarButtons.element(boundBy: index)
      guard button.exists, !excludedIdentifiers.contains(button.identifier) else {
        continue
      }
      return button
    }

    return toolbarButton(in: app, index: 0)
  }

  func sidebarFilterControl(in app: XCUIApplication) -> XCUIElement {
    let identifiedControl = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sidebarStatusPicker
    )
    if identifiedControl.exists, !identifiedControl.frame.isEmpty {
      return identifiedControl
    }

    let titledControl = button(in: app, title: "Status")
    return titledControl.exists ? titledControl : identifiedControl
  }

  func sidebarFilterControlDiagnostics(in app: XCUIApplication) -> String {
    let roles: [XCUIElement.ElementType] = [
      .button,
      .menuButton,
      .popUpButton,
      .radioButton,
      .cell,
      .any,
    ]
    var lines: [String] = []

    for role in roles {
      let identifierMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(identifier: HarnessMonitorUITestAccessibility.sidebarStatusPicker)
        .allElementsBoundByIndex
      for (index, element) in identifierMatches.enumerated() {
        lines.append(
          "identifier role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) label=\(element.label)"
        )
      }

      let titleMatches = mainWindow(in: app)
        .descendants(matching: role)
        .matching(NSPredicate(format: "label == %@", "Status"))
        .allElementsBoundByIndex
      for (index, element) in titleMatches.enumerated() {
        lines.append(
          "title role=\(role.rawValue) index=\(index) exists=\(element.exists) "
            + "hittable=\(element.isHittable) frame=\(element.frame) identifier=\(element.identifier)"
        )
      }
    }

    if lines.isEmpty {
      return "no sidebar filter accessibility candidates"
    }
    return lines.joined(separator: "\n")
  }
}
