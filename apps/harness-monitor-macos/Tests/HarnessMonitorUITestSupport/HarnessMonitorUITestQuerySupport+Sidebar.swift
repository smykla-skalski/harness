import XCTest

extension HarnessMonitorUITestCase {
  func sidebarToggleButton(in app: XCUIApplication) -> XCUIElement {
    let excludedIdentifiers: Set<String> = [
      HarnessMonitorUITestAccessibility.navigateBackButton,
      HarnessMonitorUITestAccessibility.navigateForwardButton,
      HarnessMonitorUITestAccessibility.refreshButton,
      HarnessMonitorUITestAccessibility.sleepPreventionButton,
      HarnessMonitorUITestAccessibility.sidebarFiltersCard,
      HarnessMonitorUITestAccessibility.sidebarCreateMenuButton,
      HarnessMonitorUITestAccessibility.workspaceToolbarButton,
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
    let identifiedButton = button(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sidebarFiltersCard
    )
    if identifiedButton.exists, !identifiedButton.frame.isEmpty {
      return identifiedButton
    }

    let toolbarControl = toolbarButton(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sidebarFiltersCard
    )
    if toolbarControl.exists, !toolbarControl.frame.isEmpty {
      return toolbarControl
    }

    let identifiedControl = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sidebarStatusPicker
    )
    if identifiedControl.exists, !identifiedControl.frame.isEmpty {
      return identifiedControl
    }

    let titledControl = button(in: app, title: "Filters")
    if titledControl.exists {
      return titledControl
    }

    let fallbackTitledControl = button(in: app, title: "Filter")
    if fallbackTitledControl.exists {
      return fallbackTitledControl
    }

    let filterGroup = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.sessionFilterGroup
    )
    if filterGroup.exists, !filterGroup.frame.isEmpty {
      return filterGroup
    }

    return identifiedControl
  }
}
