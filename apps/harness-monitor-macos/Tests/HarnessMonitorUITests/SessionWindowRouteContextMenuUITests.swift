import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SessionWindowRouteContextMenuUITests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let previewSessionID = "sess1234"

  func testTasksRouteContextMenuUsesBatchLabelsForMiddleColumnSelection() {
    let app = launchPreviewSessionWindow()

    let sidebarTask = element(in: app, identifier: Accessibility.sidebarTaskRow("task-ui"))
    XCTAssertTrue(waitForElement(sidebarTask, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: sidebarTask))

    let primaryRow = element(in: app, identifier: Accessibility.sessionWindowTaskRow("task-ui"))
    let secondaryRow = element(
      in: app,
      identifier: Accessibility.sessionWindowTaskRow("task-routing")
    )
    XCTAssertTrue(waitForElement(primaryRow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(secondaryRow, timeout: Self.actionTimeout))

    modifierClickElement(in: app, element: secondaryRow, modifierFlags: .command)

    XCTAssertTrue(
      rightClickElementReliably(in: app, element: secondaryRow),
      "Expected the middle-column task row to expose the shared context menu"
    )

    let copyTaskIDsItem = app.menuItems["Copy 2 Task IDs"].firstMatch
    let deleteTasksItem = app.menuItems["Delete 2 Tasks"].firstMatch
    XCTAssertTrue(copyTaskIDsItem.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(deleteTasksItem.waitForExistence(timeout: Self.fastActionTimeout))
  }

  private func launchPreviewSessionWindow() -> XCUIApplication {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [Self.previewScenarioKey: Self.dashboardLandingScenario]
    )

    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

    let sessionRowIdentifier = Accessibility.openRecentSessionRow(Self.previewSessionID)
    XCTAssertTrue(
      waitForButtonReady(
        in: app,
        identifier: sessionRowIdentifier,
        timeout: Self.actionTimeout
      )
    )

    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(sessionWindow, timeout: Self.actionTimeout))
    return app
  }

  #if os(macOS)
    private func modifierClickElement(
      in app: XCUIApplication,
      element: XCUIElement,
      modifierFlags: XCUIElement.KeyModifierFlags
    ) {
      let elementCenterCoordinate = centerCoordinate(in: app, for: element)
      let fallbackCoordinate = preferredTapCoordinate(in: app, for: element)
      let exists =
        waitForElement(element, timeout: Self.fastActionTimeout)
        || elementCenterCoordinate != nil
        || fallbackCoordinate != nil

      XCTAssertTrue(exists, "Expected row \(element.identifier) before modifier-clicking it")
      guard exists else { return }

      if app.state != .runningForeground {
        app.activate()
      }

      if let elementCenterCoordinate {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          elementCenterCoordinate.click()
        }
      } else if let fallbackCoordinate {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          fallbackCoordinate.click()
        }
      } else {
        XCUIElement.perform(withKeyModifiers: modifierFlags) {
          element.click()
        }
      }

      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }
  #endif
}
