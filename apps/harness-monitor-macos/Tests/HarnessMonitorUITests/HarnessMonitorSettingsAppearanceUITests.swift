import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsAppearanceUITests: HarnessMonitorUITestCase {
  func testSettingsThemeModePickerKeepsNativeChromeContractInAutoMode() throws {
    assertAppearanceSettingsContract(expectedMode: "auto")
  }

  func testSettingsThemeModePickerKeepsNativeChromeContractInDarkMode() throws {
    assertAppearanceSettingsContract(expectedMode: "dark")
  }

  func testSettingsThemeModePickerKeepsNativeChromeContractInLightMode() throws {
    assertAppearanceSettingsContract(expectedMode: "light")
  }

  func testRepeatedThemeModeChangesKeepSettingsAndCockpitResponsive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": "auto"]
    )

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)

    let expectedModes: [(title: String, rawValue: String)] = [
      ("Dark", "dark"),
      ("Light", "light"),
      ("Auto", "auto"),
      ("Dark", "dark"),
      ("Auto", "auto"),
    ]

    for expectedMode in expectedModes {
      let expectedState = settingsStateLabel(
        .appearance(mode: expectedMode.rawValue)
      )
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.settingsThemeModePicker,
        optionTitle: expectedMode.title
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          settingsState.label == expectedState
        },
        """
        Settings state did not settle after selecting \(expectedMode.title); got \
        '\(settingsState.label)'
        """
      )
    }

    closeSettings(in: app, settingsRoot: settingsRoot)

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (sessionRow.value as? String) == "interactive=button"
      },
      "Preview session row did not return to the idle state; got '\(sessionRow.value ?? "nil")'"
    )

    app.activate()
    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func testRepeatedBackdropModeChangesKeepSettingsAndCockpitResponsive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "none"]
    )

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let backdropPicker = element(in: app, identifier: Accessibility.settingsBackdropModePicker)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(backdropPicker.waitForExistence(timeout: Self.actionTimeout))

    for option in ["Window", "Content", "None", "Window", "None"] {
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.settingsBackdropModePicker,
        optionTitle: option
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          let currentBackdropPicker = self.element(
            in: app,
            identifier: Accessibility.settingsBackdropModePicker
          )
          return (currentBackdropPicker.value as? String) == option
        },
        "Backdrop picker did not settle after selecting \(option); got '\(backdropPicker.value ?? "nil")'"
      )
    }

    closeSettings(in: app, settingsRoot: settingsRoot)

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func testMenuBarStateColorsTogglePersistsAcrossReopeningSettings() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let menuBarStateColorsToggle = element(
      in: app,
      identifier: Accessibility.settingsMenuBarStateColorsToggle
    )

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(menuBarStateColorsToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(menuBarStateColorsToggle.value as? String, "1")

    tapElement(in: app, identifier: Accessibility.settingsMenuBarStateColorsToggle)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (menuBarStateColorsToggle.value as? String) == "0"
      },
      "Menu bar state colors toggle should turn off after it is clicked"
    )

    closeSettings(in: app, settingsRoot: settingsRoot)
    openSettings(in: app)
    selectAppearanceSection(in: app)

    let reopenedToggle = element(
      in: app,
      identifier: Accessibility.settingsMenuBarStateColorsToggle
    )
    XCTAssertTrue(reopenedToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(reopenedToggle.value as? String, "0")
  }

  func testBackgroundGalleryRecentsStayStableAcrossSelections() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        HarnessMonitorSettingsUITestKeys.backgroundImageOverride: "auroraVeil",
        "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "window",
        HarnessMonitorSettingsUITestKeys.resetBackgroundRecents: "1",
      ]
    )

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let recentSection = element(
      in: app,
      identifier: Accessibility.settingsBackgroundRecentsSection
    )
    let recentState = element(in: app, identifier: Accessibility.settingsBackgroundRecentState)
    let gallery = element(in: app, identifier: Accessibility.settingsBackgroundGallery)

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.fastActionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(gallery.waitForExistence(timeout: Self.fastActionTimeout))

    let collectionPicker = segmentedControl(
      in: app,
      identifier: Accessibility.settingsBackgroundCollectionPicker
    )
    XCTAssertTrue(collectionPicker.waitForExistence(timeout: Self.fastActionTimeout))

    let expectedRecentStates: [(background: String, recent: String)] = [
      ("blueMarble", "recent=blueMarble"),
      ("aleutianCloudbreak", "recent=aleutianCloudbreak|blueMarble"),
    ]

    for expectedSelection in expectedRecentStates {
      selectBackgroundAndAssertRecentState(
        background: expectedSelection.background,
        recent: expectedSelection.recent,
        in: app,
        settingsState: settingsState,
        recentState: recentState
      )
    }

    XCTAssertTrue(recentSection.waitForExistence(timeout: Self.fastActionTimeout))

    let nativeSegment = button(in: app, title: "Native")
    XCTAssertTrue(nativeSegment.waitForExistence(timeout: Self.fastActionTimeout))
    if let background = selectFirstExistingBackground(
      in: app,
      candidates: [
        "system:big-sur-aerial",
        "system:sonoma",
        "system:imac-blue",
      ]
    ) {
      let expectedState = settingsStateLabel(
        .appearance(
          mode: "auto",
          backdrop: "window",
          background: background
        )
      )
      assertSettledLabel(
        of: settingsState,
        equals: expectedState,
        timeout: Self.fastActionTimeout,
        message: """
          Settings state did not settle after selecting \(background); got \
          '\(settingsState.label)'
          """
      )
      assertSettledLabel(
        of: recentState,
        equals: "recent=\(background)|aleutianCloudbreak|blueMarble",
        timeout: Self.fastActionTimeout,
        message: """
          Recent backgrounds did not include \(background) at the front; got \
          '\(recentState.label)'
          """
      )
    }

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.settingsBackdropModePicker,
      optionTitle: "None"
    )
    let disabledMessage = app.staticTexts["Background image requires a backdrop"].firstMatch
    XCTAssertTrue(disabledMessage.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !recentSection.exists
      },
      "Recent backgrounds section should be hidden when backdrop is None"
    )

    closeSettings(in: app, settingsRoot: settingsRoot)
  }

  func testSettingsTextSizePickerKeepsNativeChromeContractAtLargestSize() throws {
    assertAppearanceSettingsContract(
      expectedMode: "auto",
      textSizeOverride: "6",
      expectedTextSize: "Largest",
      expectedControlSize: "large"
    )
  }

  func testSidebarSessionRowModePickerSwitchesBetweenConciseAndDetailedLayouts() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        HarnessMonitorSettingsUITestKeys.sidebarSessionRowDisplayModeOverride: "concise"
      ]
    )

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let sidebarRowModePicker = element(
      in: app,
      identifier: Accessibility.settingsSessionRowModePicker
    )
    let agentStat = element(in: app, identifier: Accessibility.previewSessionRowAgentStat)
    let taskStat = element(in: app, identifier: Accessibility.previewSessionRowTaskStat)

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))

    selectAppearanceSection(in: app)

    XCTAssertTrue(sidebarRowModePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(agentStat.exists)
    XCTAssertFalse(taskStat.exists)

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.settingsSessionRowModePicker,
      optionTitle: "Detailed"
    )

    assertSettledLabel(
      of: settingsState,
      equals: settingsStateLabel(
        .appearance(mode: "auto", sidebarRowMode: "detailed")
      ),
      timeout: Self.actionTimeout,
      message: """
        Settings state did not settle after selecting Detailed; got '\(settingsState.label)'
        """
    )

    closeSettings(in: app, settingsRoot: settingsRoot)

    XCTAssertTrue(agentStat.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(taskStat.waitForExistence(timeout: Self.fastActionTimeout))

    openSettings(in: app)
    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(sidebarRowModePicker.waitForExistence(timeout: Self.actionTimeout))

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.settingsSessionRowModePicker,
      optionTitle: "Concise"
    )

    assertSettledLabel(
      of: settingsState,
      equals: settingsStateLabel(.appearance(mode: "auto")),
      timeout: Self.actionTimeout,
      message: """
        Settings state did not settle after selecting Concise; got '\(settingsState.label)'
        """
    )

    closeSettings(in: app, settingsRoot: settingsRoot)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !agentStat.exists && !taskStat.exists
      },
      "Detailed probes should disappear again after returning to concise mode"
    )
  }

  private func assertSettledLabel(
    of element: XCUIElement,
    equals expectedLabel: String,
    timeout: TimeInterval,
    message: String
  ) {
    XCTAssertTrue(
      waitUntil(timeout: timeout) {
        element.label == expectedLabel
      },
      message
    )
  }

  private func selectBackgroundAndAssertRecentState(
    background: String,
    recent: String,
    in app: XCUIApplication,
    settingsState: XCUIElement,
    recentState: XCUIElement
  ) {
    let expectedState = settingsStateLabel(
      .appearance(mode: "auto", backdrop: "window", background: background)
    )
    tapBackgroundTile(in: app, key: background)
    assertSettledLabel(
      of: settingsState,
      equals: expectedState,
      timeout: Self.fastActionTimeout,
      message: """
        Settings state did not settle after selecting \(background); got \
        '\(settingsState.label)'
        """
    )
    assertSettledLabel(
      of: recentState,
      equals: recent,
      timeout: Self.fastActionTimeout,
      message: """
        Recent backgrounds did not settle after selecting \(background); got \
        '\(recentState.label)'
        """
    )
  }
}
