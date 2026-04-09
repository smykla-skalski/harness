import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private let textSizeOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"
private let timeZoneModeOverrideKey = "HARNESS_MONITOR_TIME_ZONE_MODE_OVERRIDE"
private let customTimeZoneOverrideKey = "HARNESS_MONITOR_CUSTOM_TIME_ZONE_OVERRIDE"
private let backgroundImageOverrideKey = "HARNESS_MONITOR_BACKGROUND_IMAGE_OVERRIDE"

@MainActor
final class HarnessMonitorSettingsUITests: HarnessMonitorUITestCase {
  func testToolbarOpensSettingsWindow() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    let title = element(in: app, identifier: Accessibility.preferencesTitle)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    let generalSection = sidebarSectionElement(
      in: app,
      title: "General",
      within: settingsWindow
    )
    let appearanceSection = element(in: app, identifier: Accessibility.preferencesAppearanceSection)

    XCTAssertTrue(generalSection.exists)
    XCTAssertTrue(appearanceSection.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "General")
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        mode: "auto",
        section: "general",
        backdrop: "none",
        background: "auroraVeil",
        textSize: "Default",
        controlSize: "small",
        timeZoneMode: "local",
        timeZone: "local"
      )
    )
  }

  func testCommandCommaOpensSingletonSettingsWindow() throws {
    let app = launch(mode: "preview")

    app.typeKey(",", modifierFlags: .command)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(preferencesRootCount(in: app), 1)

    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(preferencesRootCount(in: app), 1)
  }

  func testRemoveLaunchAgentRequiresConfirmation() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    openSettings(in: app)

    let removeButton = element(in: app, identifier: Accessibility.removeLaunchAgentButton)
    let launchdCard = element(in: app, identifier: Accessibility.preferencesLaunchdCard)
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
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.preferencesThemeModePicker,
        optionTitle: expectedMode.title
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          preferencesState.label == self.preferencesStateLabel(
            mode: expectedMode.rawValue,
            section: "appearance",
            backdrop: "none",
            background: "auroraVeil",
            textSize: "Default",
            controlSize: "small",
            timeZoneMode: "local",
            timeZone: "local"
          )
        },
        "Preferences state did not settle after selecting \(expectedMode.title); got '\(preferencesState.label)'"
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

  func testBackgroundSelectionKeepsSettingsAndCockpitResponsive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        backgroundImageOverrideKey: "auroraVeil",
        "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "none",
      ]
    )

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let gallery = element(in: app, identifier: Accessibility.preferencesBackgroundGallery)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    selectAppearanceSection(in: app)
    XCTAssertTrue(gallery.waitForExistence(timeout: Self.actionTimeout))

    for background in ["blueMarble", "gangesDelta", "auroraVeil"] {
      tapElement(in: app, identifier: Accessibility.preferencesBackgroundTile(background))

      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          preferencesState.label == self.preferencesStateLabel(
            mode: "auto",
            section: "appearance",
            backdrop: "window",
            background: background,
            textSize: "Default",
            controlSize: "small",
            timeZoneMode: "local",
            timeZone: "local"
          )
        },
        "Preferences state did not settle after selecting \(background); got '\(preferencesState.label)'"
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

  func testMacOSWallpaperSelectionKeepsSettingsAndCockpitResponsive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        backgroundImageOverrideKey: "auroraVeil",
        "HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE": "none",
      ]
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

    let background = try selectFirstExistingBackground(
      in: app,
      candidates: [
        "system:big-sur-aerial",
        "system:sonoma",
        "system:imac-blue",
      ]
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        preferencesState.label == self.preferencesStateLabel(
          mode: "auto",
          section: "appearance",
          backdrop: "window",
          background: background,
          textSize: "Default",
          controlSize: "small",
          timeZoneMode: "local",
          timeZone: "local"
        )
      },
      "Preferences state did not settle after selecting \(background); got '\(preferencesState.label)'"
    )

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

  func testSettingsTextSizePickerKeepsNativeChromeContractAtLargestSize() throws {
    assertAppearanceSettingsContract(
      expectedMode: "auto",
      textSizeOverride: "6",
      expectedTextSize: "Largest",
      expectedControlSize: "large"
    )
  }

  func testSettingsTimeZonePickerSupportsCustomZoneContract() throws {
    assertGeneralSettingsContract(
      expectedMode: "auto",
      timeZoneModeOverride: "custom",
      customTimeZoneOverride: "Europe/Warsaw",
      expectedTimeZoneMode: "custom",
      expectedTimeZone: "Europe/Warsaw"
    )
  }

}

private extension HarnessMonitorSettingsUITests {
  func assertAppearanceSettingsContract(
    expectedMode: String,
    textSizeOverride: String? = nil,
    expectedTextSize: String = "Default",
    expectedControlSize: String = "small"
  ) {
    var additionalEnvironment = ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": expectedMode]
    if let textSizeOverride {
      additionalEnvironment[textSizeOverrideKey] = textSizeOverride
    }

    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment
    )

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let modePicker = element(in: app, identifier: Accessibility.preferencesThemeModePicker)
    let textSizePicker = element(in: app, identifier: Accessibility.preferencesTextSizePicker)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectAppearanceSection(in: app)

    XCTAssertTrue(modePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(textSizePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        mode: expectedMode,
        section: "appearance",
        backdrop: "none",
        background: "auroraVeil",
        textSize: expectedTextSize,
        controlSize: expectedControlSize,
        timeZoneMode: "local",
        timeZone: "local"
      )
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    closeSettings(in: app, preferencesRoot: preferencesRoot)

    let sessionRow = previewSessionTrigger(in: app)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(sessionRow.value as? String, "interactive=button")

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      observeSummaryButton.value as? String,
      "interactive=button, chrome=content-card"
    )
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func assertGeneralSettingsContract(
    expectedMode: String,
    timeZoneModeOverride: String? = nil,
    customTimeZoneOverride: String? = nil,
    expectedTimeZoneMode: String = "local",
    expectedTimeZone: String = "local"
  ) {
    var additionalEnvironment = ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": expectedMode]
    if let timeZoneModeOverride {
      additionalEnvironment[timeZoneModeOverrideKey] = timeZoneModeOverride
    }
    if let customTimeZoneOverride {
      additionalEnvironment[customTimeZoneOverrideKey] = customTimeZoneOverride
    }

    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment
    )

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let timeZonePicker = element(in: app, identifier: Accessibility.preferencesTimeZoneModePicker)
    let customTimeZonePicker = element(
      in: app,
      identifier: Accessibility.preferencesCustomTimeZonePicker
    )

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectGeneralSection(in: app)

    XCTAssertTrue(timeZonePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        mode: expectedMode,
        section: "general",
        backdrop: "none",
        background: "auroraVeil",
        textSize: "Default",
        controlSize: "small",
        timeZoneMode: expectedTimeZoneMode,
        timeZone: expectedTimeZone
      )
    )
    XCTAssertEqual(customTimeZonePicker.exists, expectedTimeZoneMode == "custom")
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    closeSettings(in: app, preferencesRoot: preferencesRoot)

    let sessionRow = previewSessionTrigger(in: app)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(sessionRow.value as? String, "interactive=button")

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      observeSummaryButton.value as? String,
      "interactive=button, chrome=content-card"
    )
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func preferencesStateLabel(
    mode: String,
    section: String,
    backdrop: String,
    background: String,
    textSize: String,
    controlSize: String,
    timeZoneMode: String,
    timeZone: String
  ) -> String {
    [
      "mode=\(mode)",
      "section=\(section)",
      "backdrop=\(backdrop)",
      "background=\(background)",
      "textSize=\(textSize)",
      "controlSize=\(controlSize)",
      "timeZoneMode=\(timeZoneMode)",
      "timeZone=\(timeZone)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  func selectAppearanceSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesAppearanceSection,
      expectedTitle: "Appearance"
    )
  }

  func selectGeneralSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesGeneralSection,
      expectedTitle: "General"
    )
  }

  func selectPreferencesSection(
    in app: XCUIApplication,
    identifier: String,
    expectedTitle: String
  ) {
    let title = element(in: app, identifier: Accessibility.preferencesTitle)
    if title.exists, title.label == expectedTitle {
      return
    }

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let settingsWindow = window(in: app, containing: preferencesRoot)
    let section = sidebarSectionElement(
      in: app,
      title: expectedTitle,
      within: settingsWindow
    )

    XCTAssertTrue(section.waitForExistence(timeout: Self.actionTimeout))
    if section.isHittable {
      section.tap()
    } else if let coordinate = centerCoordinate(in: app, for: section) {
      coordinate.tap()
    } else {
      tapElement(in: app, identifier: identifier)
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        title.exists && title.label == expectedTitle
      },
      "Preferences title did not switch to \(expectedTitle); got '\(title.label)'"
    )
  }

  func selectFirstExistingBackground(
    in app: XCUIApplication,
    candidates: [String]
  ) throws -> String {
    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesWindow = window(in: app, containing: preferencesRoot)
    let nativeTab = app.buttons.matching(NSPredicate(format: "label == %@", "Native")).firstMatch

    XCTAssertTrue(nativeTab.waitForExistence(timeout: Self.actionTimeout))

    for _ in 0..<4 where !nativeTab.isHittable {
      dragUp(in: app, element: preferencesWindow, distanceRatio: 0.18)
    }

    XCTAssertTrue(nativeTab.isHittable, "Native background tab never became hittable")
    nativeTab.tap()

    for _ in 0..<4 {
      for candidate in candidates {
        let tile = element(in: app, identifier: Accessibility.preferencesBackgroundTile(candidate))
        if tile.waitForExistence(timeout: 1), tile.isHittable {
          tile.tap()
          return candidate
        }
      }

      dragUp(in: app, element: mainWindow(in: app), distanceRatio: 0.22)
    }

    throw XCTSkip("No expected macOS wallpaper tiles were available on this machine.")
  }

  func closeSettings(in app: XCUIApplication, preferencesRoot: XCUIElement) {
    if !preferencesRoot.exists {
      return
    }

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !preferencesRoot.exists
      }
    )
    XCTAssertTrue(mainWindow(in: app).waitForExistence(timeout: Self.actionTimeout))
  }

  func preferencesRootCount(in app: XCUIApplication) -> Int {
    app.descendants(matching: .any)
      .matching(identifier: Accessibility.preferencesRoot)
      .count
  }

  func preferencesMetricValue(in element: XCUIElement, label: String) -> XCUIElement {
    element.descendants(matching: .staticText)
      .matching(NSPredicate(format: "label == %@", label))
      .firstMatch
  }
}
