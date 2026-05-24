import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class ActionConsoleScopeUITests: HarnessMonitorUITestCase {
  private static let actionDelayKey = "HARNESS_MONITOR_TEST_ACTION_DELAY_MS"
  private static let actionDelayMilliseconds = 1_200

  func testCreateTaskSpinnerScoping() throws {
    let app = launchInCockpitPreview()

    let createTaskButton = button(in: app, identifier: Accessibility.createTaskButton)
    XCTAssertTrue(createTaskButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(
      createTaskButton.isEnabled,
      "Create Task starts disabled when no title has been typed"
    )

    fillCreateTaskTitle(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createTaskButton.isEnabled },
      "Create Task should become enabled after typing a title"
    )

    tapViaCoordinate(in: app, element: createTaskButton)

    let observeButton = button(in: app, identifier: Accessibility.observeSessionButton)
    let endSessionButton = button(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        observeButton.exists && !observeButton.isEnabled
      },
      "Other action buttons must disable while Create Task runs - proves per-button scoping"
    )
    XCTAssertFalse(
      endSessionButton.isEnabled,
      "End Session must also disable while Create Task runs"
    )
    XCTAssertTrue(
      createTaskButton.isEnabled,
      "Create Task itself should remain enabled (it is the in-flight action)"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { observeButton.isEnabled },
      "Other buttons should re-enable after Create Task completes"
    )
  }

  func testOtherButtonsDisabledDuringAction() throws {
    let app = launchInCockpitPreview()

    let createTaskButton = button(in: app, identifier: Accessibility.createTaskButton)
    XCTAssertTrue(createTaskButton.waitForExistence(timeout: Self.actionTimeout))
    fillCreateTaskTitle(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createTaskButton.isEnabled }
    )

    tapViaCoordinate(in: app, element: createTaskButton)

    let gatedButtonIdentifiers = [
      Accessibility.observeSessionButton,
      Accessibility.endSessionButton,
    ]

    for identifier in gatedButtonIdentifiers {
      let gatedButton = button(in: app, identifier: identifier)
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          gatedButton.exists && !gatedButton.isEnabled
        },
        "Button \(identifier) must be disabled while Create Task runs"
      )
    }
  }

  func testButtonsReEnableAfterCompletion() throws {
    let app = launchInCockpitPreview()

    let createTaskButton = button(in: app, identifier: Accessibility.createTaskButton)
    XCTAssertTrue(createTaskButton.waitForExistence(timeout: Self.actionTimeout))
    fillCreateTaskTitle(in: app)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { createTaskButton.isEnabled }
    )

    tapViaCoordinate(in: app, element: createTaskButton)

    let observeButton = button(in: app, identifier: Accessibility.observeSessionButton)
    let endSessionButton = button(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !observeButton.isEnabled
      },
      "Observe should be disabled mid-action"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        observeButton.isEnabled && endSessionButton.isEnabled
      },
      "All action buttons should re-enable after the action completes"
    )
    XCTAssertFalse(
      createTaskButton.isEnabled,
      "Create Task re-disables after success because the title field clears"
    )
  }
}

extension ActionConsoleScopeUITests {
  fileprivate func launchInCockpitPreview() -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
        Self.actionDelayKey: String(Self.actionDelayMilliseconds),
      ]
    )
  }

  fileprivate func fillCreateTaskTitle(in app: XCUIApplication) {
    let titleField = editableField(in: app, identifier: Accessibility.createTaskTitleField)
    XCTAssertTrue(titleField.waitForExistence(timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: titleField)
    titleField.typeText("Scoped spinner verification task")
  }

  fileprivate func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard tapElementReliably(in: app, element: element) else {
      XCTFail("Cannot resolve coordinate for \(element)")
      return
    }
  }
}
