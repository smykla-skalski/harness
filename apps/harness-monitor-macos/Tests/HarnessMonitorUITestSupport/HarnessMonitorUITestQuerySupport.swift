import XCTest

extension HarnessMonitorUITestCase {
  private static var maxWindowSearchCount: Int { 4 }
  static var maxToolbarButtonSearchCount: Int { 12 }

  func previewSessionTrigger(in app: XCUIApplication) -> XCUIElement {
    sessionTrigger(in: app, identifier: HarnessMonitorUITestAccessibility.previewSessionRow)
  }

  func sessionTrigger(in app: XCUIApplication, identifier: String) -> XCUIElement {
    for candidateIdentifier in sessionTriggerIdentifiers(for: identifier) {
      let identifiedButton = button(in: app, identifier: candidateIdentifier)
      if identifiedButton.exists {
        return identifiedButton
      }

      let cell = app.cells.matching(identifier: candidateIdentifier).firstMatch
      if cell.exists {
        return cell
      }

      let identifiedElement = element(in: app, identifier: candidateIdentifier)
      if identifiedElement.exists {
        return identifiedElement
      }
    }

    return element(in: app, identifier: identifier)
  }

  func focusChip(in app: XCUIApplication, identifier: String, title: String) -> XCUIElement {
    let identifiedElement = element(in: app, identifier: identifier)
    return identifiedElement.exists ? identifiedElement : button(in: app, title: title)
  }

  func mainWindow(in app: XCUIApplication) -> XCUIElement {
    let mainContentIdentifiers = [
      HarnessMonitorUITestAccessibility.appChromeRoot,
      HarnessMonitorUITestAccessibility.openRecentRoot,
      HarnessMonitorUITestAccessibility.sessionWindowShell,
    ]
    for identifier in mainContentIdentifiers {
      if let mainWindowIdentifier = windowIdentifier(
        in: app,
        containingDescendantIdentifier: identifier
      ) {
        return app.windows.matching(identifier: mainWindowIdentifier).firstMatch
      }
    }

    let mainIdentifierWindow = app.windows.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "main-")
    ).firstMatch
    return mainIdentifierWindow.exists ? mainIdentifierWindow : app.windows.firstMatch
  }

  func appChromeRoot(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: HarnessMonitorUITestAccessibility.appChromeRoot)
      .firstMatch
  }

  func openRecentRoot(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: HarnessMonitorUITestAccessibility.openRecentRoot)
      .firstMatch
  }

  func window(in app: XCUIApplication, containing element: XCUIElement) -> XCUIElement {
    let windows = app.windows
    let searchCount = min(windows.count, Self.maxWindowSearchCount)
    let identifier = element.identifier.trimmingCharacters(in: .whitespacesAndNewlines)

    if !identifier.isEmpty {
      if let windowIdentifier = windowIdentifier(
        in: app,
        containingDescendantIdentifier: identifier
      ) {
        return app.windows.matching(identifier: windowIdentifier).firstMatch
      }
    }

    var bestWindowIdentifier: String?
    var bestWindowArea = CGFloat.greatestFiniteMagnitude
    for index in 0..<searchCount {
      let candidate = windows.element(boundBy: index)
      guard candidate.exists, candidate.frame.contains(element.frame) else {
        continue
      }

      let candidateIdentifier = candidate.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !candidateIdentifier.isEmpty else {
        continue
      }

      let candidateArea = candidate.frame.width * candidate.frame.height
      if candidateArea < bestWindowArea {
        bestWindowArea = candidateArea
        bestWindowIdentifier = candidateIdentifier
      }
    }
    if let bestWindowIdentifier {
      return app.windows.matching(identifier: bestWindowIdentifier).firstMatch
    }

    let primaryWindow = mainWindow(in: app)
    if primaryWindow.exists {
      return primaryWindow
    }

    return app.windows.firstMatch
  }

  private func windowIdentifier(
    in app: XCUIApplication,
    containingDescendantIdentifier identifier: String
  ) -> String? {
    let windows = app.windows
    let searchCount = min(windows.count, Self.maxWindowSearchCount)
    var bestWindowIdentifier: String?
    var bestWindowArea = CGFloat.greatestFiniteMagnitude

    for index in 0..<searchCount {
      let candidate = windows.element(boundBy: index)
      guard candidate.exists else {
        continue
      }
      let descendantMatch = candidate.descendants(matching: .any)
        .matching(identifier: identifier)
        .firstMatch
      guard descendantMatch.exists else {
        continue
      }

      let candidateIdentifier = candidate.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !candidateIdentifier.isEmpty else {
        continue
      }

      let candidateArea = candidate.frame.width * candidate.frame.height
      if candidateArea < bestWindowArea {
        bestWindowArea = candidateArea
        bestWindowIdentifier = candidateIdentifier
      }
    }

    return bestWindowIdentifier
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

  private func sessionTriggerIdentifiers(for identifier: String) -> [String] {
    guard identifier == HarnessMonitorUITestAccessibility.previewSessionRow else {
      return [identifier]
    }
    return [
      HarnessMonitorUITestAccessibility.openRecentSessionRow("sess1234"),
      identifier,
    ]
  }

  func descendantButton(in container: XCUIElement, identifier: String) -> XCUIElement {
    let roles: [XCUIElement.ElementType] = [
      .button,
      .menuButton,
      .radioButton,
      .cell,
    ]

    for role in roles {
      let match = container.descendants(matching: role)
        .matching(identifier: identifier)
        .firstMatch
      if match.exists {
        return match
      }
    }

    return descendantElement(in: container, identifier: identifier)
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

}
