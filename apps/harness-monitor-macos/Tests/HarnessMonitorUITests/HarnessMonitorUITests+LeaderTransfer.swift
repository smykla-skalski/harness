import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private let textSizeOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"

@MainActor
extension HarnessMonitorUITests {
  func testSessionActionsExposeActorPickerAndRemoveAgentFlow() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let actorPicker = element(in: app, identifier: Accessibility.actionActorPicker)
    let removeAgentButton = element(in: app, identifier: Accessibility.removeAgentButton)

    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(removeAgentButton.waitForExistence(timeout: Self.actionTimeout))
  }

  func testTaskInspectorShowsCheckpointNotesAndSuggestedFix() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let inspectorCard = element(in: app, identifier: Accessibility.taskInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Checkpoint"].exists)
    XCTAssertTrue(app.staticTexts["Suggested Fix"].exists)
    XCTAssertTrue(
      app.staticTexts["Merged daemon timeline entries with session checkpoints."].exists
    )
  }

  func testAgentInspectorShowsRuntimeCapabilitiesAndToolActivity() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorCard = element(in: app, identifier: Accessibility.agentInspectorCard)
    let sendSignalButton = element(in: app, identifier: Accessibility.signalSendButton)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sendSignalButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Runtime Capabilities"].exists)
    XCTAssertTrue(app.staticTexts["Tool Activity"].exists)
    XCTAssertTrue(app.staticTexts["PreToolUse · 5s · context"].exists)
    XCTAssertTrue(app.staticTexts["Edit"].exists)
  }

  func testAgentInspectorKeepsNativeFormControlsUsableAtLargestTextSize() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [textSizeOverrideKey: "6"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let actorPicker = popUpButton(in: app, identifier: Accessibility.actionActorPicker)
    let commandField = editableField(in: app, identifier: Accessibility.signalCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.signalMessageField)

    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(commandField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(messageField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    for _ in 0..<4 {
      if actorPicker.isHittable, commandField.isHittable, messageField.isHittable {
        break
      }
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.18)
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        actorPicker.isHittable && commandField.isHittable && messageField.isHittable
      }
    )
  }

  func testObserverInspectorShowsCycleHistoryAndTrackedSessions() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let inspectorCard = element(in: app, identifier: Accessibility.observerInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Cycle History"].exists)
    XCTAssertTrue(app.staticTexts["Tracked Agent Sessions"].exists)
    XCTAssertTrue(app.staticTexts["Cursor 104"].exists)
  }

  func testEndSessionRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    XCTAssertTrue(endSessionButton.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(app.buttons["End Session Now"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["End Session?"].exists)
    dismissConfirmationDialog(in: app)
  }

  func testSidebarSearchFieldFiltersSessions() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))

    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    app.typeText("zzznomatch")

    if !noMatches.waitForExistence(timeout: Self.actionTimeout) {
      attachWindowScreenshot(in: app, named: "sidebar-search-not-hittable")
    }
    XCTAssertTrue(noMatches.exists)
  }

  func testCommandFMovesFocusToNativeSidebarSearchField() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)
    app.typeKey("f", modifierFlags: .command)
    app.typeText("zzznomatch")

    XCTAssertTrue(
      noMatches.waitForExistence(timeout: Self.actionTimeout),
      "Cmd-F should move focus to the native sidebar search field and filter sessions"
    )
  }

  func testLeaderTransferSectionShowsPickerWithCurrentLeaderDimmed() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

    let transferSection = element(in: app, identifier: Accessibility.leaderTransferSection)
    let transferButton = button(in: app, title: "Transfer Leadership")

    for _ in 0..<8 where !transferButton.exists {
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.25)
    }

    XCTAssertTrue(transferSection.exists, "Leader transfer section should be visible")
    XCTAssertTrue(transferButton.exists, "Transfer button should be visible")
    XCTAssertTrue(
      app.staticTexts["Leader Transfer"].exists,
      "Section header should read Leader Transfer"
    )
  }

  func testLeaderTransferSectionIsDisabledForSingleAgentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "single-agent"]
    )

    tapSession(in: app, identifier: Accessibility.singleAgentSessionRow)

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

    let transferSection = element(in: app, identifier: Accessibility.leaderTransferSection)

    for _ in 0..<8 where !transferSection.exists {
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.25)
    }

    XCTAssertTrue(transferSection.exists, "Leader transfer section should be in the tree")
    XCTAssertFalse(transferSection.isEnabled, "Section should be disabled with only one agent")
  }
}
