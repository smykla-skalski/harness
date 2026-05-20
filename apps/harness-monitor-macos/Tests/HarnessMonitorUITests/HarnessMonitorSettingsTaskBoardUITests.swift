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
      "Task Board settings should keep shared secrets in the dedicated Secrets section"
    )
    XCTAssertFalse(
      todoistProjectField.exists,
      "Task Board settings should hide Todoist inbox controls while the integration is disabled"
    )
    XCTAssertFalse(status.exists, "Task Board preview should not settle on a status error")
  }
}

@MainActor
final class HarnessMonitorSettingsDependenciesAndSecretsUITests: HarnessMonitorUITestCase {
  func testDependenciesSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectDependenciesSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsDependenciesSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsDependenciesReloadButton)
    let authorsField = element(in: app, identifier: Accessibility.settingsDependenciesAuthorsField)
    let mergeMethodField = element(
      in: app,
      identifier: Accessibility.settingsDependenciesMergeMethodField
    )

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(authorsField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(mergeMethodField.exists)
  }

  func testSecretsSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectSecretsSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsSecretsSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsSecretsReloadButton)
    let githubTokenField = element(in: app, identifier: Accessibility.settingsTaskBoardGlobalTokenField)
    let todoistTokenField = element(
      in: app,
      identifier: "\(Accessibility.settingsTaskBoardGlobalTokenField).todoist"
    )
    let sshKeyPathField = element(in: app, identifier: Accessibility.settingsTaskBoardSSHKeyPathField)
    let status = element(in: app, identifier: Accessibility.settingsSecretsStatus)

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(githubTokenField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(todoistTokenField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sshKeyPathField.exists)
    XCTAssertFalse(status.exists, "Secrets preview should not settle on a status error")
  }
}
