import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsDatabaseUITests: HarnessMonitorUITestCase {
  func testDatabaseSectionStatisticsButtonsAndConfirmations() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))

    // Click "Database" in the sidebar. Sidebar items may appear as buttons,
    // cells, or radio buttons depending on the macOS version.
    let databaseItem = button(in: app, title: "Database")
    XCTAssertTrue(databaseItem.waitForExistence(timeout: 2), "Database sidebar item not found")
    tapViaCoordinate(in: app, element: databaseItem)

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
    XCTAssertTrue(statisticsHeader.waitForExistence(timeout: 2))

    // -- Scroll to reveal Operations buttons --
    dragUp(in: app, element: statisticsHeader, distanceRatio: 3.0)

    // -- Verify operation buttons --
    let clearCacheButton = app.buttons["Clear Session Cache"].firstMatch
    let clearUserDataButton = app.buttons["Clear User Data"].firstMatch
    let clearAllButton = app.buttons["Clear All Data"].firstMatch
    let revealButton = app.buttons["Reveal in Finder"].firstMatch

    XCTAssertTrue(clearCacheButton.waitForExistence(timeout: 2), "Clear Session Cache not found")
    XCTAssertTrue(clearUserDataButton.exists, "Clear User Data not found")
    XCTAssertTrue(clearAllButton.exists, "Clear All Data not found")
    XCTAssertTrue(revealButton.exists, "Reveal in Finder not found")

    // -- Clear Session Cache confirmation --
    tapViaCoordinate(in: app, element: clearCacheButton)
    let clearCacheConfirm = confirmationDialogButton(in: app, title: "Clear Session Cache Now")
    XCTAssertTrue(clearCacheConfirm.waitForExistence(timeout: 2), "Cache confirm dialog missing")
    dismissConfirmationDialog(in: app)
    XCTAssertTrue(
      waitUntil(timeout: 2) { !clearCacheConfirm.exists },
      "Cache confirm dialog should dismiss after Cancel"
    )

    // -- Clear User Data confirmation --
    tapViaCoordinate(in: app, element: clearUserDataButton)
    let clearUserConfirm = confirmationDialogButton(in: app, title: "Clear User Data Now")
    XCTAssertTrue(clearUserConfirm.waitForExistence(timeout: 2), "User data confirm dialog missing")
    dismissConfirmationDialog(in: app)
    XCTAssertTrue(
      waitUntil(timeout: 2) { !clearUserConfirm.exists },
      "User data confirm dialog should dismiss after Cancel"
    )

    // -- Clear All Data confirmation --
    tapViaCoordinate(in: app, element: clearAllButton)
    let clearAllConfirm = confirmationDialogButton(in: app, title: "Clear All Data Now")
    XCTAssertTrue(clearAllConfirm.waitForExistence(timeout: 2), "Clear all confirm dialog missing")
    dismissConfirmationDialog(in: app)
    XCTAssertTrue(
      waitUntil(timeout: 2) { !clearAllConfirm.exists },
      "Clear all confirm dialog should dismiss after Cancel"
    )

    // -- Scroll further to Health section --
    dragUp(in: app, element: clearCacheButton, distanceRatio: 3.0)

    let schemaVersionLabel = app.staticTexts["Schema Version"].firstMatch
    XCTAssertTrue(
      schemaVersionLabel.waitForExistence(timeout: 2),
      "Schema Version should be visible in the Health section"
    )
  }

  func testDatabaseStatisticsUseNativeSegmentedControl() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesDatabaseSection,
      expectedTitle: "Database"
    )

    let statisticsPicker = segmentedControl(
      in: app,
      identifier: Accessibility.preferencesDatabaseStatisticsPicker
    )
    XCTAssertTrue(statisticsPicker.waitForExistence(timeout: Self.actionTimeout))

    let storageSegment = button(in: app, title: "Storage")
    XCTAssertTrue(storageSegment.waitForExistence(timeout: Self.actionTimeout))

    storageSegment.tap()

    let appCacheSizeLabel = app.staticTexts["App Cache Size"].firstMatch
    XCTAssertTrue(appCacheSizeLabel.waitForExistence(timeout: Self.actionTimeout))
  }
}

extension HarnessMonitorSettingsDatabaseUITests {
  /// Tap an element via its center coordinate. Avoids the hittability check
  /// that can fail for elements inside custom layouts like WrapLayout.
  fileprivate func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard tapElementReliably(in: app, element: element) else {
      XCTFail("Cannot resolve coordinate for \(element)")
      return
    }
  }
}
