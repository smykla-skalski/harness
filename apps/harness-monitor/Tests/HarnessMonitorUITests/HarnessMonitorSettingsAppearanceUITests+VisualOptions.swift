import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorSettingsAppearanceUITests {
  func testSessionVisualOptionTogglesCanBeDisabledTogether() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let shortcutOverlaysToggle = element(
      in: app,
      identifier: Accessibility.settingsSessionShortcutOverlaysToggle
    )
    let titleBlurToggle = element(
      in: app,
      identifier: Accessibility.settingsSessionTitleBlurToggle
    )
    let menuBarStateColorsToggle = element(
      in: app,
      identifier: Accessibility.settingsMenuBarStateColorsToggle
    )

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(shortcutOverlaysToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(titleBlurToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(menuBarStateColorsToggle.waitForExistence(timeout: Self.actionTimeout))

    tapElement(in: app, identifier: Accessibility.settingsSessionShortcutOverlaysToggle)
    tapElement(in: app, identifier: Accessibility.settingsSessionTitleBlurToggle)
    tapElement(in: app, identifier: Accessibility.settingsMenuBarStateColorsToggle)

    let expectedState = settingsStateLabel(
      .appearance(
        mode: "auto",
        sidebarRowMode: "strict",
        shortcutOverlays: "disabled",
        titleBlur: "disabled",
        menuBarStateColors: "disabled"
      )
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        settingsState.label == expectedState
      },
      """
      Settings state did not settle after disabling visual options; got \
      '\(settingsState.label)'
      """
    )

    closeSettings(in: app, settingsRoot: settingsRoot)
  }
}
