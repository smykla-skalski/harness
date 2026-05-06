import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsWindowUITests: HarnessMonitorUITestCase {
  func testToolbarOpensSettingsWindow() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let settingsPanel = frameElement(in: app, identifier: Accessibility.settingsPanel)
    let title = element(in: app, identifier: Accessibility.settingsTitle)

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))

    let settingsWindow = window(in: app, containing: settingsPanel)
    let generalSection = sidebarSectionElement(
      in: app,
      title: "General",
      within: settingsWindow
    )
    let appearanceSection = element(in: app, identifier: Accessibility.settingsAppearanceSection)

    XCTAssertTrue(generalSection.exists)
    XCTAssertTrue(appearanceSection.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "General")
    XCTAssertEqual(
      settingsState.label,
      settingsStateLabel(.general(mode: "auto"))
    )
  }

  func testCommandCommaOpensSingletonSettingsWindow() throws {
    let app = launch(mode: "preview")

    app.typeKey(",", modifierFlags: .command)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(settingsRootCount(in: app), 1)

    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(settingsRootCount(in: app), 1)
  }

  func testRemoveLaunchAgentRequiresConfirmation() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    openSettings(in: app)

    let removeButton = element(in: app, identifier: Accessibility.removeLaunchAgentButton)
    let launchdCard = element(in: app, identifier: Accessibility.settingsLaunchdCard)
    if !removeButton.waitForExistence(timeout: Self.actionTimeout) {
      attachAppHierarchy(in: app, named: "remove-launch-agent-hierarchy")
    }

    XCTAssertTrue(removeButton.exists)
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (launchdCard.value as? String)?.contains("Running") == true
      },
      "Launchd card value should contain 'Running' but got '\(launchdCard.value ?? "nil")'"
    )

    tapElement(in: app, identifier: Accessibility.removeLaunchAgentButton)

    let confirmButton = confirmationDialogButton(
      in: app,
      title: "Remove Launch Agent Now"
    )
    XCTAssertTrue(
      confirmButton.waitForExistence(timeout: Self.actionTimeout)
    )
    confirmButton.tap()
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (launchdCard.value as? String)?.contains("Manual") == true
      }
    )
  }
}
