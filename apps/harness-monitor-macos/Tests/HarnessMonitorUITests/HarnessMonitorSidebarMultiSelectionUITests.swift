import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSidebarMultiSelectionUITests: HarnessMonitorUITestCase {
  func testCommandClickKeepsCockpitPinnedToCurrentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")
    let secondaryHeaderTitle = cockpitTitle(in: app, text: "Signal retention verification")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && secondarySelection.exists
      },
      "Command-click should extend the sidebar selection"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
    XCTAssertFalse(
      secondaryHeaderTitle.exists,
      "Command-click while multi-selecting must not retarget the cockpit"
    )
  }

  func testShiftClickKeepsCockpitPinnedToCurrentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")
    let secondaryHeaderTitle = cockpitTitle(in: app, text: "Signal retention verification")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    clickSession(
      in: app,
      identifier: Accessibility.previewSessionRow,
      allowAlreadySelected: true
    )

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .shift
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && secondarySelection.exists
      },
      "Shift-click should extend the sidebar selection range"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
    XCTAssertFalse(
      secondaryHeaderTitle.exists,
      "Shift-click while multi-selecting must not retarget the cockpit"
    )
  }

  func testPlainClickCarriesRowActionAndCollapsesMultiSelection() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")
    let secondaryHeaderTitle = cockpitTitle(in: app, text: "Signal retention verification")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command,
      settleAfterClick: false
    )

    clickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      allowAlreadySelected: true
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !primarySelection.exists && secondarySelection.exists
      },
      "Plain click should collapse the sidebar selection to the clicked row immediately"
    )
    XCTAssertTrue(secondaryHeaderTitle.exists)
    XCTAssertFalse(
      primaryHeaderTitle.exists,
      "Plain click should still perform the row's normal cockpit navigation"
    )
  }

  func testClickingTrailingSidebarWhitespaceKeepsCurrentCockpitSessionSelected() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let sessionListContent = frameElement(
      in: app,
      identifier: Accessibility.sidebarSessionListContent
    )
    let mainWindow = app.windows.firstMatch
    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command,
      settleAfterClick: false
    )
    XCTAssertTrue(waitForElement(sessionListContent, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(mainWindow, timeout: Self.fastActionTimeout))
    let whitespacePoint = CGPoint(
      x: sessionListContent.frame.midX,
      y: sessionListContent.frame.minY + (sessionListContent.frame.height * 0.85)
    )
    mainWindow.coordinate(withNormalizedOffset: .zero)
      .withOffset(
        CGVector(
          dx: whitespacePoint.x - mainWindow.frame.minX,
          dy: whitespacePoint.y - mainWindow.frame.minY
        )
      )
      .click()

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && !secondarySelection.exists
      },
      "Clicking trailing blank sidebar space should collapse the selection to the current cockpit session"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
  }

  func testPlainClickInCockpitCollapsesMultiSelectionToCurrentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let primaryHeaderTitle = cockpitTitle(in: app, text: "Harness Monitor Cockpit")

    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primaryHeaderTitle, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command,
      settleAfterClick: false
    )
    XCTAssertTrue(
      clickVisibleFrameMarker(
        in: app,
        identifier: Accessibility.sessionHeaderCard
      ),
      "Expected to click the cockpit header card"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && !secondarySelection.exists
      },
      "Clicking in the cockpit should collapse the sidebar multi-selection to the current session"
    )
    XCTAssertTrue(primaryHeaderTitle.exists)
  }

  func testMultiSelectionContextMenuUsesPluralLabelsAndRemovesAllSelectedSessions() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primaryRow = element(in: app, identifier: Accessibility.previewSessionRow)
    let secondaryRow = element(in: app, identifier: Accessibility.sessionRow("sess5678"))
    let primarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySelection = sessionSelectionFrame(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    let dashboard = element(in: app, identifier: Accessibility.sessionsBoardRoot)

    XCTAssertTrue(waitForElement(primaryRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(primarySelection, timeout: Self.fastActionTimeout))

    modifierClickSession(
      in: app,
      identifier: Accessibility.sessionRow("sess5678"),
      modifierFlags: .command
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        primarySelection.exists && secondarySelection.exists
      },
      "Command-click should extend the sidebar selection before opening the shared context menu"
    )
    XCTAssertTrue(
      rightClickElementReliably(in: app, element: secondaryRow),
      "A selected sidebar row should expose a context menu for the whole multi-selection"
    )

    let bookmarkItem = app.menuItems["Bookmark Sessions"].firstMatch
    let copyTitlesItem = app.menuItems["Copy Titles"].firstMatch
    let copySessionIDsItem = app.menuItems["Copy Session IDs"].firstMatch
    let removeSessionsItem = app.menuItems["Remove Sessions..."].firstMatch

    XCTAssertTrue(bookmarkItem.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(copyTitlesItem.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(copySessionIDsItem.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(removeSessionsItem.waitForExistence(timeout: Self.fastActionTimeout))

    removeSessionsItem.tap()

    let confirmButton = confirmationDialogButton(in: app, title: "Remove 2 Sessions Now")
    let title = app.staticTexts["Remove 2 Sessions?"].firstMatch
    let message = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "This removes 2 selected sessions")
    ).firstMatch

    XCTAssertTrue(confirmButton.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(title.exists)
    XCTAssertTrue(message.exists)
    confirmButton.tap()

    XCTAssertTrue(waitForElement(dashboard, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) { !primaryRow.exists && !secondaryRow.exists },
      "Confirming the plural remove action should remove every selected sidebar session"
    )
  }

  private func cockpitTitle(in app: XCUIApplication, text: String) -> XCUIElement {
    let cockpitScroll = element(in: app, identifier: Accessibility.sessionCockpitScrollView)
    return cockpitScroll.descendants(matching: .staticText)
      .matching(NSPredicate(format: "label == %@ OR value == %@", text, text))
      .firstMatch
  }

  private func sessionSelectionFrame(
    in app: XCUIApplication,
    identifier: String
  ) -> XCUIElement {
    element(in: app, identifier: "\(identifier).selection.frame")
  }
}
