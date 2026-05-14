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
    let status = element(in: app, identifier: Accessibility.settingsTaskBoardStatus)

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.exists)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        ownerField.exists || status.exists
      },
      "Task Board settings should load editable fields or surface a status message"
    )
  }
}
