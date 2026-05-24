import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AuthorizedFoldersTests: HarnessMonitorUITestCase {
  func testPreseedBookmarkShowsReadableHarnessNameInPrefs() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PRESEED_BOOKMARK": "1"]
    )

    // Open settings via keyboard shortcut. Avoids menu-bar interaction
    // which requires TCC and is flaky in XCUITest (see
    // feedback_xcuitest_absolute_coords_tcc).
    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))

    // Navigate to Authorized Folders via the sidebar.
    selectSettingsSection(
      in: app,
      identifier: Accessibility.settingsAuthorizedFoldersSection,
      expectedTitle: "Authorized Folders"
    )

    // The preseed record with id "B-preseed" must appear in the list.
    let row = app.descendants(matching: .any)
      .matching(identifier: Accessibility.settingsAuthorizedFolderRow("B-preseed"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: Self.actionTimeout))

    XCTAssertTrue(
      app.staticTexts["harness"].firstMatch.waitForExistence(
        timeout: Self.actionTimeout
      ),
      "The seeded authorized folder should use a readable harness label"
    )
  }
}
