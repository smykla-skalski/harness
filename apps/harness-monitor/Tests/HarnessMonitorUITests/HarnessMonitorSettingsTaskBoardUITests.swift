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
    let repositoriesButton = element(
      in: app,
      identifier: Accessibility.settingsTaskBoardRepositoriesButton
    )
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
    XCTAssertTrue(
      repositoriesButton.exists,
      "Task Board settings should link monitored repositories to the shared Repositories section"
    )
    XCTAssertFalse(
      todoistTokenField.exists,
      "Task Board settings should keep shared secrets in the dedicated Secrets section"
    )
    XCTAssertFalse(
      element(in: app, identifier: Accessibility.settingsTaskBoardInboxRepositoriesField).exists,
      "Task Board settings should not edit inbox repositories inline anymore"
    )
    XCTAssertFalse(
      todoistProjectField.exists,
      "Task Board settings should hide Todoist inbox controls while the integration is disabled"
    )
    XCTAssertFalse(status.exists, "Task Board preview should not settle on a status error")
  }

  func testRepositoriesSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectRepositoriesSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsRepositoriesSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsRepositoriesReloadButton)
    let root = element(in: app, identifier: Accessibility.settingsRepositoriesRoot)

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.exists)
    XCTAssertTrue(root.exists)
  }
}

@MainActor
final class HarnessMonitorSettingsDepsUITests: HarnessMonitorUITestCase {
  func testReviewsSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectReviewsSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsReviewsSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsReviewsReloadButton)
    let excludedReposField = element(
      in: app,
      identifier: Accessibility.settingsReviewsExcludedReposField
    )
    let repositoriesButton = element(
      in: app,
      identifier: Accessibility.settingsReviewsRepositoriesButton
    )
    let mergeMethodField = element(
      in: app,
      identifier: Accessibility.settingsReviewsMergeMethodField
    )

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(excludedReposField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(repositoriesButton.exists)
    XCTAssertTrue(mergeMethodField.exists)
    XCTAssertFalse(
      element(in: app, identifier: Accessibility.settingsReviewsRepositoriesField).exists,
      "Reviews settings should not edit repository scope inline anymore"
    )
  }

  func testSecretsSectionAppearsInSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectSecretsSection(in: app)

    let saveButton = element(in: app, identifier: Accessibility.settingsSecretsSaveButton)
    let reloadButton = element(in: app, identifier: Accessibility.settingsSecretsReloadButton)
    let githubTokenField = element(
      in: app, identifier: Accessibility.settingsTaskBoardGlobalTokenField)
    let todoistTokenField = element(
      in: app,
      identifier: "\(Accessibility.settingsTaskBoardGlobalTokenField).todoist"
    )
    let sshKeyPathField = element(
      in: app, identifier: Accessibility.settingsTaskBoardSSHKeyPathField)
    let status = element(in: app, identifier: Accessibility.settingsSecretsStatus)

    XCTAssertTrue(saveButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(reloadButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(githubTokenField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(todoistTokenField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sshKeyPathField.exists)
    XCTAssertFalse(status.exists, "Secrets preview should not settle on a status error")
  }
}
