import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SessionWindowRouteContextMenuUITests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let previewSessionID = "sess1234"

  func testSidebarShowsRoutesWhileDeferredSectionsLoad() {
    let app = launchPreviewSessionWindow()

    let overviewRoute = element(in: app, identifier: Accessibility.sessionWindowRoute("overview"))
    let deferredLoader = element(
      in: app,
      identifier: Accessibility.sessionWindowSidebarDeferredLoader
    )
    let taskRow = element(in: app, identifier: Accessibility.sidebarTaskRow("task-ui"))

    XCTAssertTrue(
      waitForElement(in: app, overviewRoute, timeout: Self.fastActionTimeout),
      "Expected static route rows to appear before deferred sidebar content finishes mounting"
    )
    XCTAssertTrue(
      waitForElement(in: app, deferredLoader, timeout: Self.fastActionTimeout),
      "Expected a visible loader while deferred sidebar sections are still hidden"
    )
    XCTAssertTrue(
      waitForElement(in: app, taskRow, timeout: Self.actionTimeout),
      "Expected deferred sidebar rows to appear once the native list mounts"
    )
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.actionTimeout) { !deferredLoader.exists },
      "Expected the deferred sidebar loader to disappear after the native list mounts"
    )
  }

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

  func testAgentRouteContextMenuTargetsRightClickedRowWhenAnotherAgentIsOpen() {
    let app = launchPreviewSessionWindow()

    let agentsRoute = element(in: app, identifier: Accessibility.sessionWindowRoute("agents"))
    XCTAssertTrue(waitForElement(agentsRoute, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: agentsRoute))

    let primaryRow = element(
      in: app,
      identifier: Accessibility.sessionWindowAgentRow("leader-claude")
    )
    let secondaryRow = element(
      in: app,
      identifier: Accessibility.sessionWindowAgentRow("worker-codex")
    )
    XCTAssertTrue(waitForElement(primaryRow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(secondaryRow, timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: primaryRow))

    XCTAssertTrue(
      rightClickElementReliably(in: app, element: secondaryRow),
      "Expected the middle-column agent row to expose the shared context menu"
    )

    let removeAgentItem = app.menuItems["Remove Agent"].firstMatch
    XCTAssertTrue(removeAgentItem.waitForExistence(timeout: Self.fastActionTimeout))
    activatePresentedMenuItem(in: app, item: removeAgentItem, title: "Remove Agent")

    let confirmButton = confirmationDialogButton(in: app, title: "Remove Agent Now")
    XCTAssertTrue(confirmButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: confirmButton))
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.actionTimeout) { !secondaryRow.exists },
      "Expected the right-clicked agent row to disappear after confirmation"
    )
    XCTAssertTrue(primaryRow.exists)
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
    private func activatePresentedMenuItem(
      in app: XCUIApplication,
      item: XCUIElement,
      title: String
    ) {
      if item.isHittable {
        item.click()
        return
      }
      if let coordinate = preferredTapCoordinate(in: app, for: item) {
        coordinate.click()
        return
      }
      XCTFail("Failed to activate presented menu item \(title)")
    }

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
