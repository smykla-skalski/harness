import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsTaskBoardUITests: HarnessMonitorUITestCase {
  func testTaskBoardSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectTaskBoardSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsTaskBoardSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsTaskBoardReloadButton)
    let ownerField = element(in: app, identifier: Accessibility.settingsTaskBoardOwnerField)
    let todoistTokenField = element(
      in: app,
      identifier: Accessibility.settingsTaskBoardTodoistTokenField
    )
    let todoistProjectField = element(
      in: app,
      identifier: "harness.settings.task-board.todoist-inbox.project-filter"
    )
    let status = element(in: app, identifier: Accessibility.settingsTaskBoardStatus)

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.exists)
    XCTAssertTrue(
      ownerField.waitForExistence(timeout: Self.actionTimeout),
      "Task Board settings should load editable fields"
    )
    XCTAssertFalse(
      todoistTokenField.exists,
      "Task Board settings should hide Todoist token while the integration is disabled"
    )
    XCTAssertFalse(
      todoistProjectField.exists,
      "Task Board settings should hide Todoist inbox controls while the integration is disabled"
    )
    XCTAssertFalse(status.exists, "Task Board preview should not settle on a status error")
  }
}
