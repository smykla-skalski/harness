import XCTest

struct PreferencesStateSnapshot {
  let mode: String
  let section: String
  let backdrop: String
  let background: String
  let textSize: String
  let controlSize: String
  let timeZoneMode: String
  let timeZone: String

  static func general(
    mode: String,
    backdrop: String = "none",
    background: String = "auroraVeil",
    textSize: String = "Default",
    controlSize: String = "small",
    timeZoneMode: String = "local",
    timeZone: String = "local"
  ) -> Self {
    Self(
      mode: mode,
      section: "general",
      backdrop: backdrop,
      background: background,
      textSize: textSize,
      controlSize: controlSize,
      timeZoneMode: timeZoneMode,
      timeZone: timeZone
    )
  }

  static func appearance(
    mode: String,
    backdrop: String = "none",
    background: String = "auroraVeil",
    textSize: String = "Default",
    controlSize: String = "small",
    timeZoneMode: String = "local",
    timeZone: String = "local"
  ) -> Self {
    Self(
      mode: mode,
      section: "appearance",
      backdrop: backdrop,
      background: background,
      textSize: textSize,
      controlSize: controlSize,
      timeZoneMode: timeZoneMode,
      timeZone: timeZone
    )
  }

  static func voice(
    mode: String,
    backdrop: String = "none",
    background: String = "auroraVeil",
    textSize: String = "Default",
    controlSize: String = "small",
    timeZoneMode: String = "local",
    timeZone: String = "local"
  ) -> Self {
    Self(
      mode: mode,
      section: "voice",
      backdrop: backdrop,
      background: background,
      textSize: textSize,
      controlSize: controlSize,
      timeZoneMode: timeZoneMode,
      timeZone: timeZone
    )
  }
}

extension HarnessMonitorUITestCase {
  func assertAppearanceSettingsContract(
    expectedMode: String,
    textSizeOverride: String? = nil,
    expectedTextSize: String = "Default",
    expectedControlSize: String = "small"
  ) {
    var additionalEnvironment = ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": expectedMode]
    if let textSizeOverride {
      additionalEnvironment[HarnessMonitorSettingsUITestKeys.textSizeOverride] = textSizeOverride
    }

    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment
    )

    openSettings(in: app)

    let preferencesRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesRoot
    )
    let preferencesState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesState
    )
    let appChromeState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.appChromeState
    )
    let modePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesThemeModePicker
    )
    let textSizePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesTextSizePicker
    )

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectAppearanceSection(in: app)

    XCTAssertTrue(modePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(textSizePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        .appearance(
          mode: expectedMode,
          textSize: expectedTextSize,
          controlSize: expectedControlSize
        )
      )
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    closeSettings(in: app, preferencesRoot: preferencesRoot)

    let sessionRow = previewSessionTrigger(in: app)
    let observeSummaryButton = app.buttons
      .matching(identifier: HarnessMonitorUITestAccessibility.observeSummaryButton)
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
      additionalEnvironment[HarnessMonitorSettingsUITestKeys.timeZoneModeOverride] =
        timeZoneModeOverride
    }
    if let customTimeZoneOverride {
      additionalEnvironment[HarnessMonitorSettingsUITestKeys.customTimeZoneOverride] =
        customTimeZoneOverride
    }

    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment
    )

    openSettings(in: app)

    let preferencesRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesRoot
    )
    let preferencesState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesState
    )
    let appChromeState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.appChromeState
    )
    let timeZonePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesTimeZoneModePicker
    )
    let customTimeZonePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesCustomTimeZonePicker
    )

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectGeneralSection(in: app)

    XCTAssertTrue(timeZonePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(
        .general(
          mode: expectedMode,
          timeZoneMode: expectedTimeZoneMode,
          timeZone: expectedTimeZone
        )
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
      .matching(identifier: HarnessMonitorUITestAccessibility.observeSummaryButton)
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

  func preferencesStateLabel(_ snapshot: PreferencesStateSnapshot) -> String {
    [
      "mode=\(snapshot.mode)",
      "section=\(snapshot.section)",
      "backdrop=\(snapshot.backdrop)",
      "background=\(snapshot.background)",
      "textSize=\(snapshot.textSize)",
      "controlSize=\(snapshot.controlSize)",
      "timeZoneMode=\(snapshot.timeZoneMode)",
      "timeZone=\(snapshot.timeZone)",
      "preferencesChrome=native",
    ].joined(separator: ", ")
  }
}
