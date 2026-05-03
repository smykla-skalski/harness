import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceWindowKeyboardParityUITests: HarnessMonitorUITestCase, WorkspaceWindowUITestSupporting {
  func testSpaceKeyScrollsCreatePane() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)

    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let promptFrame = frameElement(
      in: app,
      identifier: Accessibility.agentTuiPromptField
    )

    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(promptFrame, timeout: Self.actionTimeout))

    let initialPromptY = promptFrame.frame.minY
    app.typeKey(.space, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        promptFrame.frame.minY < initialPromptY - 12
      },
      """
      Space should scroll the create pane down the same way Page Down does.
      initialY=\(initialPromptY)
      currentY=\(promptFrame.frame.minY)
      """
    )
  }

  func testShiftSpaceKeyScrollsCreatePaneUp() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)

    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let promptFrame = frameElement(
      in: app,
      identifier: Accessibility.agentTuiPromptField
    )

    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(promptFrame, timeout: Self.actionTimeout))

    app.typeKey(.space, modifierFlags: [])
    let scrolledDownY = promptFrame.frame.minY
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        promptFrame.frame.minY < scrolledDownY + 12
      }
    )

    app.typeKey(.space, modifierFlags: .shift)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        promptFrame.frame.minY > scrolledDownY + 12
      },
      """
      Shift-Space should scroll the create pane up.
      downY=\(scrolledDownY)
      currentY=\(promptFrame.frame.minY)
      """
    )
  }

  func testSpaceIsConsumedByFocusedTextField() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)

    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let promptField = editableField(in: app, identifier: Accessibility.agentTuiPromptField)
    let promptFrame = frameElement(
      in: app,
      identifier: Accessibility.agentTuiPromptField
    )

    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(promptField, timeout: Self.actionTimeout))

    promptField.click()
    let initialFrameY = promptFrame.frame.minY

    app.typeKey(.space, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (promptField.value as? String)?.contains(" ") == true
      },
      "Space should type into the focused text field, not scroll."
    )

    let finalFrameY = promptFrame.frame.minY
    XCTAssertTrue(
      abs(finalFrameY - initialFrameY) < 40,
      """
      Paging should be suppressed while a text field is focused.
      initialY=\(initialFrameY)
      finalY=\(finalFrameY)
      """
    )
  }
}
