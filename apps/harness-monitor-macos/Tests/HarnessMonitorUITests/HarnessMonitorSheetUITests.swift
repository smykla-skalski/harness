import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSheetUITests: HarnessMonitorUITestCase {
  func testSendSignalSheetPresentsAndDismissesWithEscape() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    // Verify sheet appeared.
    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(
      sheetRoot.waitForExistence(timeout: Self.actionTimeout),
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
      waitUntil(timeout: 2) { !sheetRoot.exists },
      "Sheet should dismiss on Escape"
    )
  }

  func testSendSignalSheetDismissesWithCancelButton() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.actionTimeout))

    // Dismiss via Cancel button.
    let cancelButton = button(in: app, identifier: Accessibility.sendSignalSheetCancelButton)
    XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
    tapViaCoordinate(in: app, element: cancelButton)

    XCTAssertTrue(
      waitUntil(timeout: 2) { !sheetRoot.exists },
      "Sheet should dismiss on Cancel"
    )
  }

  func testSendSignalSheetFormInteraction() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let sheetRoot = element(in: app, identifier: Accessibility.sendSignalSheet)
    XCTAssertTrue(sheetRoot.waitForExistence(timeout: Self.actionTimeout))

    // Command field should have default value "inject_context".
    let commandField = editableField(in: app, identifier: Accessibility.sendSignalSheetCommandField)
    XCTAssertTrue(commandField.waitForExistence(timeout: 2))

    // Type into message field.
    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    XCTAssertTrue(messageField.waitForExistence(timeout: 2))
    tapViaCoordinate(in: app, element: messageField)
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

  func testSendSignalVoicePopoverRecordsPreviewTranscript() throws {
    let app = launchInCockpitPreview()

    openSendSignalSheet(in: app)

    let voiceButton = button(in: app, identifier: Accessibility.sendSignalSheetMessageVoiceButton)
    XCTAssertTrue(voiceButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: voiceButton)

    let popover = element(in: app, identifier: Accessibility.voiceInputPopover)
    XCTAssertTrue(
      popover.waitForExistence(timeout: Self.actionTimeout),
      "Voice input popover should open from the message field"
    )

    let recordButton = button(in: app, identifier: Accessibility.voiceInputStopButton)
    XCTAssertTrue(recordButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(recordButton.label.contains("Record"))
    tapViaCoordinate(in: app, element: recordButton)

    let transcript = element(in: app, identifier: Accessibility.voiceInputTranscript)
    let transcriptText = app.staticTexts["Preview voice input for Harness Monitor"].firstMatch
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (transcript.exists
          && transcript.label.contains("Preview voice input for Harness Monitor"))
          || transcriptText.exists
      },
      "Preview voice capture should produce a transcript without microphone access"
    )

    let insertButton = button(in: app, identifier: Accessibility.voiceInputInsertButton)
    XCTAssertTrue(insertButton.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: insertButton)

    let messageField = editableField(in: app, identifier: Accessibility.sendSignalSheetMessageField)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let value = messageField.value as? String
        return value?.contains("Preview voice input for Harness Monitor") == true
      },
      "Inserted voice transcript should update the message field"
    )
  }
}

extension HarnessMonitorSheetUITests {
  fileprivate func launchInCockpitPreview() -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
  }

  /// Right-click the already-loaded leader agent card to open the "Send Signal"
  /// context menu item.
  fileprivate func openSendSignalSheet(in app: XCUIApplication) {
    let agentCard = button(in: app, identifier: Accessibility.leaderAgentCard)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        agentCard.exists && !agentCard.frame.isEmpty
      },
      "Leader agent card should be visible in cockpit preview"
    )

    agentCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

    let signalMenuItem = app.menuItems["Send Signal"].firstMatch
    XCTAssertTrue(
      signalMenuItem.waitForExistence(timeout: Self.actionTimeout),
      "Send Signal menu item should appear"
    )
    signalMenuItem.tap()
  }

  fileprivate func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
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
