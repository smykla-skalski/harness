import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension WorkspaceWindowUITests {
  func testCreatePanePageKeysScrollOnOpenAndReactivation() throws {
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
    app.typeKey(.pageDown, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        promptFrame.frame.minY < initialPromptY - 12
      },
      """
      Page Down should scroll the create pane as soon as the workspace window opens.
      initialY=\(initialPromptY)
      currentY=\(promptFrame.frame.minY)
      """
    )

    let scrolledPromptY = promptFrame.frame.minY
    invokeMenuItem(in: app, menu: "Window", title: "Main")
    invokeMenuItem(in: app, menu: "Window", title: "Workspace")

    XCTAssertTrue(waitForElement(launchPane, timeout: Self.actionTimeout))
    app.typeKey(.pageUp, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        promptFrame.frame.minY > scrolledPromptY + 12
      },
      """
      After the workspace window becomes key again, Page Up should still target the create pane.
      downY=\(scrolledPromptY)
      currentY=\(promptFrame.frame.minY)
      """
    )
  }

  func testWorkspacePreservesFocusedEditorAcrossReactivation() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)

    let promptField = editableField(in: app, identifier: Accessibility.agentTuiPromptField)
    XCTAssertTrue(waitForElement(promptField, timeout: Self.actionTimeout))

    promptField.click()
    promptField.typeText("keep")

    invokeMenuItem(in: app, menu: "Window", title: "Main")
    invokeMenuItem(in: app, menu: "Window", title: "Workspace")

    app.typeText("focus")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (promptField.value as? String)?.contains("keepfocus") == true
      },
      """
      Reactivating the workspace window should preserve the focused editor
      instead of resetting to the sidebar or detail scroll view.
      value=\(String(describing: promptField.value))
      """
    )
  }
}
