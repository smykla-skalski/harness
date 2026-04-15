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

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)

    let expectedModes: [(title: String, rawValue: String)] = [
      ("Dark", "dark"),
      ("Light", "light"),
      ("Auto", "auto"),
      ("Dark", "dark"),
      ("Auto", "auto"),
    ]

    for expectedMode in expectedModes {
      let expectedState = preferencesStateLabel(
        .appearance(mode: expectedMode.rawValue)
      )
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.preferencesThemeModePicker,
        optionTitle: expectedMode.title
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          preferencesState.label == expectedState
        },
        """
        Preferences state did not settle after selecting \(expectedMode.title); got \
        '\(preferencesState.label)'
        """
      )
    }

    closeSettings(in: app, preferencesRoot: preferencesRoot)

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

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let backdropPicker = element(in: app, identifier: Accessibility.preferencesBackdropModePicker)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(backdropPicker.waitForExistence(timeout: Self.actionTimeout))

    for option in ["Window", "Content", "None", "Window", "None"] {
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.preferencesBackdropModePicker,
        optionTitle: option
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          let currentBackdropPicker = self.element(
            in: app,
            identifier: Accessibility.preferencesBackdropModePicker
          )
          return (currentBackdropPicker.value as? String) == option
        },
        "Backdrop picker did not settle after selecting \(option); got '\(backdropPicker.value ?? "nil")'"
      )
    }

    closeSettings(in: app, preferencesRoot: preferencesRoot)

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func testBackgroundGalleryRecentsStayStableAcrossSelections() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        HarnessMonitorSettingsUITestKeys.backgroundImageOverride: "auroraVeil",
        "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "window",
        "HARNESS_MONITOR_RESET_BACKGROUND_RECENTS": "1",
      ]
    )

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let recentSection = element(
      in: app,
      identifier: Accessibility.preferencesBackgroundRecentsSection
    )
    let recentState = element(in: app, identifier: Accessibility.preferencesBackgroundRecentState)
    let gallery = element(in: app, identifier: Accessibility.preferencesBackgroundGallery)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.fastActionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(gallery.waitForExistence(timeout: Self.fastActionTimeout))

    let collectionPicker = segmentedControl(
      in: app,
      identifier: Accessibility.preferencesBackgroundCollectionPicker
    )
    XCTAssertTrue(collectionPicker.waitForExistence(timeout: Self.fastActionTimeout))

    let expectedRecentStates: [(background: String, recent: String)] = [
      ("blueMarble", "recent=blueMarble"),
      ("aleutianCloudbreak", "recent=aleutianCloudbreak|blueMarble"),
    ]

    for expectedSelection in expectedRecentStates {
      let expectedState = preferencesStateLabel(
        .appearance(mode: "auto", backdrop: "window", background: expectedSelection.background)
      )
      tapBackgroundTile(in: app, key: expectedSelection.background)

      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          preferencesState.label == expectedState
        },
        """
        Preferences state did not settle after selecting \(expectedSelection.background); got \
        '\(preferencesState.label)'
        """
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          recentState.label == expectedSelection.recent
        },
        """
        Recent backgrounds did not settle after selecting \(expectedSelection.background); got \
        '\(recentState.label)'
        """
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
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          preferencesState.label
            == self.preferencesStateLabel(
              .appearance(
                mode: "auto",
                backdrop: "window",
                background: background
              )
            )
        },
        "Preferences state did not settle after selecting \(background); got '\(preferencesState.label)'"
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.fastActionTimeout) {
          recentState.label == "recent=\(background)|aleutianCloudbreak|blueMarble"
        },
        "Recent backgrounds did not include \(background) at the front; got '\(recentState.label)'"
      )
    }

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.preferencesBackdropModePicker,
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

    closeSettings(in: app, preferencesRoot: preferencesRoot)
  }

  func testSettingsTextSizePickerKeepsNativeChromeContractAtLargestSize() throws {
    assertAppearanceSettingsContract(
      expectedMode: "auto",
      textSizeOverride: "6",
      expectedTextSize: "Largest",
      expectedControlSize: "large"
    )
  }
}
