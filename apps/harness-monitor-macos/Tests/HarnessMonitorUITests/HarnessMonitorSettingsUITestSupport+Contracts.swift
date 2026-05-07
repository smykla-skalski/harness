import XCTest

struct SettingsStateSnapshot {
  let mode: String
  let section: String
  let backdrop: String
  let background: String
  let textSize: String
  let controlSize: String
  let sidebarRowMode: String
  let timeZoneMode: String
  let timeZone: String

  static func general(
    mode: String,
    backdrop: String = "none",
    background: String = "auroraVeil",
    textSize: String = "Default",
    controlSize: String = "small",
    sidebarRowMode: String = "concise",
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
      sidebarRowMode: sidebarRowMode,
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
    sidebarRowMode: String = "concise",
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
      sidebarRowMode: sidebarRowMode,
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
    sidebarRowMode: String = "concise",
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
      sidebarRowMode: sidebarRowMode,
      timeZoneMode: timeZoneMode,
      timeZone: timeZone
    )
  }
}

extension HarnessMonitorUITestCase {
  func assertAppearanceSettingsContract(
    expectedMode: String,
    textSizeOverride: String? = nil,
    sidebarRowModeOverride: String? = nil,
    expectedTextSize: String = "Default",
    expectedControlSize: String = "small",
    expectedSidebarRowMode: String = "concise"
  ) {
    var additionalEnvironment = ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": expectedMode]
    if let textSizeOverride {
      additionalEnvironment[HarnessMonitorSettingsUITestKeys.textSizeOverride] = textSizeOverride
    }
    if let sidebarRowModeOverride {
      additionalEnvironment[HarnessMonitorSettingsUITestKeys.sidebarSessionRowDisplayModeOverride] =
        sidebarRowModeOverride
    }

    let app = launch(
      mode: "preview",
      additionalEnvironment: additionalEnvironment
    )

    openSettings(in: app)

    let settingsRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsRoot
    )
    let settingsState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsState
    )
    let appChromeState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.appChromeState
    )
    let modePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsThemeModePicker
    )
    let textSizePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsTextSizePicker
    )

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectAppearanceSection(in: app)

    XCTAssertTrue(modePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(textSizePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      settingsState.label,
      settingsStateLabel(
        .appearance(
          mode: expectedMode,
          textSize: expectedTextSize,
          controlSize: expectedControlSize,
          sidebarRowMode: expectedSidebarRowMode
        )
      )
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    closeSettings(in: app, settingsRoot: settingsRoot)

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

    let settingsRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsRoot
    )
    let settingsState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsState
    )
    let appChromeState = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.appChromeState
    )
    let timeZonePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsTimeZoneModePicker
    )
    let customTimeZonePicker = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsCustomTimeZonePicker
    )

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))

    selectGeneralSection(in: app)

    XCTAssertTrue(timeZonePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      settingsState.label,
      settingsStateLabel(
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

    closeSettings(in: app, settingsRoot: settingsRoot)

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

  func settingsStateLabel(_ snapshot: SettingsStateSnapshot) -> String {
    [
      "mode=\(snapshot.mode)",
      "section=\(snapshot.section)",
      "backdrop=\(snapshot.backdrop)",
      "background=\(snapshot.background)",
      "textSize=\(snapshot.textSize)",
      "controlSize=\(snapshot.controlSize)",
      "sidebarRowMode=\(snapshot.sidebarRowMode)",
      "timeZoneMode=\(snapshot.timeZoneMode)",
      "timeZone=\(snapshot.timeZone)",
      "settingsChrome=native",
    ].joined(separator: ", ")
  }
}
