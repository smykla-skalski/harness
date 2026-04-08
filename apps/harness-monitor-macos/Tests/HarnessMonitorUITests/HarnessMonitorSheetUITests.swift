import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSheetUITests: HarnessMonitorUITestCase {
  func testSendSignalSheetPresentsAndDismissesWithEscape() throws {
    let app = launch(mode: "preview")

    // Navigate to cockpit with agents visible.
    tapPreviewSession(in: app)

    let agentCard = button(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(agentCard.waitForExistence(timeout: Self.uiTimeout))

    // Right-click agent card to open context menu, then tap "Send Signal".
    agentCard.rightClick()
    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(signalMenuItem.waitForExistence(timeout: Self.uiTimeout))
    signalMenuItem.tap()

    // Verify sheet appeared.
    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.uiTimeout),
      "Send Signal sheet should appear after context menu tap"
    )

    // Verify form fields exist.
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    let submitButton = button(in: app, identifier: Accessibility.sendSignalSheetSubmitButton)

    XCTAssertTrue(commandField.exists, "Command field should exist")
    XCTAssertTrue(messageField.exists, "Message field should exist")
    XCTAssertTrue(cancelButton.exists, "Cancel button should exist")
    XCTAssertTrue(submitButton.exists, "Submit button should exist")

    // Dismiss with Escape.
    app.typeKey(.escape, modifierFlags: [])
    RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))

    XCTAssertTrue(
      waitUntil(timeout: 3) { !sheetRoot.exists },
      "Sheet should dismiss on Escape"
    )
  }

  func testSendSignalSheetDismissesWithCancelButton() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)

    let agentCard = button(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(agentCard.waitForExistence(timeout: Self.uiTimeout))

    agentCard.rightClick()
    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(signalMenuItem.waitForExistence(timeout: Self.uiTimeout))
    signalMenuItem.tap()

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.uiTimeout))

    // Dismiss via Cancel button.
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
    tapViaCoordinate(in: app, element: cancelButton)

    XCTAssertTrue(
      waitUntil(timeout: 3) { !sheetRoot.exists },
      "Sheet should dismiss on Cancel"
    )
  }

  func testSendSignalSheetFormInteraction() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)

    let agentCard = button(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(agentCard.waitForExistence(timeout: Self.uiTimeout))

    agentCard.rightClick()
    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(signalMenuItem.waitForExistence(timeout: Self.uiTimeout))
    signalMenuItem.tap()

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.uiTimeout))

    // Command field should have default value "inject_context".
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    XCTAssertTrue(commandField.waitForExistence(timeout: 2))

    // Type into message field.
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    XCTAssertTrue(messageField.waitForExistence(timeout: 2))
    messageField.tap()
    messageField.typeText("Review the latest changes")

    // Verify submit button exists and is accessible.
    let submitButton = button(in: app, identifier: Accessibility.sendSignalSheetSubmitButton)
    XCTAssertTrue(submitButton.exists, "Submit button should exist")

    // Verify action hint field exists.
    let actionHintField = editableField(
      in: app,
      identifier: Accessibility.sendSignalSheetActionHintField
    )
    XCTAssertTrue(actionHintField.exists, "Action hint field should exist")

    // Clean up.
    app.typeKey(.escape, modifierFlags: [])
  }
}

private extension HarnessMonitorSheetUITests {
  func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    if element.isHittable {
      element.tap()
      return
    }
    guard let coordinate = centerCoordinate(in: app, for: element) else {
      XCTFail("Cannot resolve coordinate for \(element)")
      return
    }
    coordinate.tap()
  }
}
