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

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    let generalSection = sidebarSectionElement(
      in: app,
      title: "General",
      within: settingsWindow
    )

    XCTAssertTrue(generalSection.exists)
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "General")
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        mode: "auto",
        section: "general",
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
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(preferencesRootCount(in: app), 1)

    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
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
    if !removeButton.waitForExistence(timeout: Self.uiTimeout) {
      attachAppHierarchy(in: app, named: "remove-launch-agent-hierarchy")
    }

    XCTAssertTrue(removeButton.exists)
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
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
      confirmButton.waitForExistence(timeout: Self.uiTimeout)
    )
    confirmButton.tap()
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        (launchdCard.value as? String)?.contains("Manual") == true
      }
    )
  }

  func testSettingsThemeModePickerKeepsNativeChromeContractInAutoMode() throws {
    assertSettingsThemeModeContract(expectedMode: "auto")
  }

  func testSettingsThemeModePickerKeepsNativeChromeContractInDarkMode() throws {
    assertSettingsThemeModeContract(expectedMode: "dark")
  }

  func testSettingsThemeModePickerKeepsNativeChromeContractInLightMode() throws {
    assertSettingsThemeModeContract(expectedMode: "light")
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

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))

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
        waitUntil(timeout: Self.uiTimeout) {
          preferencesState.label == self.preferencesStateLabel(
            mode: expectedMode.rawValue,
            section: "general",
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
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
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

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(backdropPicker.waitForExistence(timeout: Self.uiTimeout))

    for option in ["Window", "Content", "None", "Window", "None"] {
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.preferencesBackdropModePicker,
        optionTitle: option
      )

      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          (backdropPicker.value as? String) == option
        },
        "Backdrop picker did not settle after selecting \(option); got '\(backdropPicker.value ?? "nil")'"
      )
    }

    closeSettings(in: app, preferencesRoot: preferencesRoot)

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
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
    let backdropPicker = element(in: app, identifier: Accessibility.preferencesBackdropModePicker)
    let gallery = element(in: app, identifier: Accessibility.preferencesBackgroundGallery)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(backdropPicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(gallery.waitForExistence(timeout: Self.uiTimeout))

    for background in ["blueMarble", "gangesDelta", "auroraVeil"] {
      tapElement(in: app, identifier: Accessibility.preferencesBackgroundTile(background))

      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          (backdropPicker.value as? String) == "Window"
        },
        "Backdrop picker did not auto-enable after selecting \(background); got '\(backdropPicker.value ?? "nil")'"
      )
      XCTAssertTrue(
        waitUntil(timeout: Self.uiTimeout) {
          preferencesState.label == self.preferencesStateLabel(
            mode: "auto",
            section: "general",
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
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
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
    let backdropPicker = element(in: app, identifier: Accessibility.preferencesBackdropModePicker)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(backdropPicker.waitForExistence(timeout: Self.uiTimeout))

    let background = try selectFirstExistingBackground(
      in: app,
      candidates: [
        "system:big-sur-aerial",
        "system:sonoma",
        "system:imac-blue",
      ]
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        (backdropPicker.value as? String) == "Window"
      },
      "Backdrop picker did not auto-enable after selecting \(background); got '\(backdropPicker.value ?? "nil")'"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        preferencesState.label == self.preferencesStateLabel(
          mode: "auto",
          section: "general",
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
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      sessionRow.value as? String,
      "selected, interactive=button, selectionChrome=translucent"
    )
  }

  func testSettingsTextSizePickerKeepsNativeChromeContractAtLargestSize() throws {
    assertSettingsThemeModeContract(
      expectedMode: "auto",
      textSizeOverride: "6",
      expectedTextSize: "Largest",
      expectedControlSize: "large"
    )
  }

  func testSettingsTimeZonePickerSupportsCustomZoneContract() throws {
    assertSettingsThemeModeContract(
      expectedMode: "auto",
      timeZoneModeOverride: "custom",
      customTimeZoneOverride: "Europe/Warsaw",
      expectedTimeZoneMode: "custom",
      expectedTimeZone: "Europe/Warsaw"
    )
  }
}

private extension HarnessMonitorSettingsUITests {
  func assertSettingsThemeModeContract(
    expectedMode: String,
    textSizeOverride: String? = nil,
    expectedTextSize: String = "Default",
    expectedControlSize: String = "small",
    timeZoneModeOverride: String? = nil,
    customTimeZoneOverride: String? = nil,
    expectedTimeZoneMode: String = "local",
    expectedTimeZone: String = "local"
  ) {
    var additionalEnvironment = ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": expectedMode]
    if let textSizeOverride {
      additionalEnvironment[textSizeOverrideKey] = textSizeOverride
    }
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
    let modePicker = element(in: app, identifier: Accessibility.preferencesThemeModePicker)
    let textSizePicker = element(in: app, identifier: Accessibility.preferencesTextSizePicker)
    let timeZonePicker = element(in: app, identifier: Accessibility.preferencesTimeZoneModePicker)
    let customTimeZonePicker = element(
      in: app,
      identifier: Accessibility.preferencesCustomTimeZonePicker
    )

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(modePicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(textSizePicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(timeZonePicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        mode: expectedMode,
        section: "general",
        background: "auroraVeil",
        textSize: expectedTextSize,
        controlSize: expectedControlSize,
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

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(sessionRow.value as? String, "interactive=button")

    tapPreviewSession(in: app)

    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
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
    background: String,
    textSize: String,
    controlSize: String,
    timeZoneMode: String,
    timeZone: String
  ) -> String {
    [
      "mode=\(mode)",
      "section=\(section)",
      "background=\(background)",
      "textSize=\(textSize)",
      "controlSize=\(controlSize)",
      "timeZoneMode=\(timeZoneMode)",
      "timeZone=\(timeZone)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }

  func selectFirstExistingBackground(
    in app: XCUIApplication,
    candidates: [String]
  ) throws -> String {
    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesWindow = window(in: app, containing: preferencesRoot)
    let disclosure = button(in: app, identifier: Accessibility.preferencesSystemBackgroundsDisclosure)

    XCTAssertTrue(disclosure.waitForExistence(timeout: Self.uiTimeout))

    for _ in 0..<4 where !disclosure.isHittable {
      dragUp(in: app, element: preferencesWindow, distanceRatio: 0.18)
    }

    XCTAssertTrue(disclosure.isHittable, "System wallpapers toggle never became hittable")
    disclosure.tap()

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

  func openSettings(in app: XCUIApplication) {
    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    if preferencesRoot.exists {
      return
    }

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)

    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
  }

  func closeSettings(in app: XCUIApplication, preferencesRoot: XCUIElement) {
    if !preferencesRoot.exists {
      return
    }

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        !preferencesRoot.exists
      }
    )
    XCTAssertTrue(mainWindow(in: app).waitForExistence(timeout: Self.uiTimeout))
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
