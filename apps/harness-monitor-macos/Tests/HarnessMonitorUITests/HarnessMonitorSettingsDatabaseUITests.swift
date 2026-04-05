import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsDatabaseUITests: HarnessMonitorUITestCase {
  func testDatabaseSectionStatisticsButtonsAndConfirmations() throws {
    let app = launch(mode: "preview")

    // Open preferences.
    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))

    // Click "Database" in the sidebar.
    let databaseSidebarItem = app.outlines.buttons.matching(
      NSPredicate(format: "label == %@", "Database")
    ).firstMatch
    if !databaseSidebarItem.waitForExistence(timeout: 2) {
      tapButton(in: app, title: "Database")
    } else {
      databaseSidebarItem.tap()
    }

    // Verify Database section loaded.
    let title = element(in: app, identifier: Accessibility.preferencesTitle)
    XCTAssertTrue(
      waitUntil(timeout: 2) { title.exists && title.label == "Database" },
      "Title should be 'Database' but got '\(title.label)'"
    )

    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    XCTAssertTrue(preferencesState.exists)
    XCTAssertTrue(preferencesState.label.contains("section=database"))

    // -- Verify Statistics section (visible at the top) --
    let statisticsHeader = app.staticTexts["Statistics"]
    XCTAssertTrue(statisticsHeader.waitForExistence(timeout: 3))

    // -- Scroll to reveal Operations buttons --
    dragUp(in: app, element: statisticsHeader, distanceRatio: 3.0)

    // -- Verify operation buttons exist --
    let clearCacheButton = app.buttons["Clear Session Cache"]
    let clearUserDataButton = app.buttons["Clear User Data"]
    let clearAllButton = app.buttons["Clear All Data"]
    let revealButton = app.buttons["Reveal in Finder"]

    XCTAssertTrue(clearCacheButton.waitForExistence(timeout: 3), "Clear Session Cache not found")
    XCTAssertTrue(clearUserDataButton.exists, "Clear User Data not found")
    XCTAssertTrue(clearAllButton.exists, "Clear All Data not found")
    XCTAssertTrue(revealButton.exists, "Reveal in Finder not found")

    // -- Clear Session Cache confirmation --
    tapButton(in: app, title: "Clear Session Cache")
    let clearCacheConfirm = confirmationDialogButton(in: app, title: "Clear Session Cache")
    XCTAssertTrue(clearCacheConfirm.waitForExistence(timeout: 2), "Cache confirm dialog missing")
    app.typeKey(.escape, modifierFlags: [])
    RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))

    // -- Clear User Data confirmation --
    tapButton(in: app, title: "Clear User Data")
    let clearUserConfirm = confirmationDialogButton(in: app, title: "Clear User Data")
    XCTAssertTrue(clearUserConfirm.waitForExistence(timeout: 2), "User data confirm dialog missing")
    app.typeKey(.escape, modifierFlags: [])
    RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))

    // -- Clear All Data confirmation --
    tapButton(in: app, title: "Clear All Data")
    let clearAllConfirm = confirmationDialogButton(in: app, title: "Clear All Data")
    XCTAssertTrue(clearAllConfirm.waitForExistence(timeout: 2), "Clear all confirm dialog missing")
    app.typeKey(.escape, modifierFlags: [])

    // -- Scroll further to Health section --
    dragUp(in: app, element: clearCacheButton, distanceRatio: 3.0)

    let schemaVersionLabel = app.staticTexts["Schema Version"]
    XCTAssertTrue(schemaVersionLabel.waitForExistence(timeout: 2), "Schema Version not found")
  }
}
