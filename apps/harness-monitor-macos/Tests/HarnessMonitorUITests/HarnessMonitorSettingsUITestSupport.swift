import XCTest

enum HarnessMonitorSettingsUITestKeys {
  static let textSizeOverride = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"
  static let timeZoneModeOverride = "HARNESS_MONITOR_TIME_ZONE_MODE_OVERRIDE"
  static let customTimeZoneOverride = "HARNESS_MONITOR_CUSTOM_TIME_ZONE_OVERRIDE"
  static let backgroundImageOverride = "HARNESS_MONITOR_BACKGROUND_IMAGE_OVERRIDE"
  static let resetBackgroundRecents = "HARNESS_MONITOR_RESET_BACKGROUND_RECENTS"
  static let voiceLocaleOverride = "HARNESS_MONITOR_VOICE_LOCALE_OVERRIDE"
  static let voiceInsertionModeOverride = "HARNESS_MONITOR_VOICE_INSERTION_MODE_OVERRIDE"
  static let voiceRemoteProcessorEnabledOverride =
    "HARNESS_MONITOR_VOICE_REMOTE_PROCESSOR_ENABLED_OVERRIDE"
  static let voiceRemoteProcessorURLOverride = "HARNESS_MONITOR_VOICE_REMOTE_PROCESSOR_URL_OVERRIDE"
}

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

  func selectAppearanceSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesAppearanceSection,
      expectedTitle: "Appearance"
    )
  }

  func selectNotificationsSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesNotificationsSection,
      expectedTitle: "Notifications"
    )
  }

  func selectVoiceSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesVoiceSection,
      expectedTitle: "Voice"
    )
  }

  func selectGeneralSection(in app: XCUIApplication) {
    selectPreferencesSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesGeneralSection,
      expectedTitle: "General"
    )
  }

  func selectPreferencesSection(
    in app: XCUIApplication,
    identifier: String,
    expectedTitle: String
  ) {
    let title = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesTitle
    )
    if title.exists, title.label == expectedTitle {
      return
    }

    let sectionAppeared = waitUntil(timeout: Self.fastActionTimeout) {
      let identifiedSection = self.button(in: app, identifier: identifier)
      if identifiedSection.exists {
        return true
      }
      return self.button(in: app, title: expectedTitle).exists
    }
    XCTAssertTrue(sectionAppeared, "\(expectedTitle) sidebar item not found")

    let section = {
      let identifiedSection = button(in: app, identifier: identifier)
      return identifiedSection.exists ? identifiedSection : button(in: app, title: expectedTitle)
    }()
    if section.isHittable {
      section.tap()
    } else if let coordinate = centerCoordinate(in: app, for: section) {
      coordinate.tap()
    } else {
      tapElement(in: app, identifier: identifier)
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        title.exists && title.label == expectedTitle
      },
      "Preferences title did not switch to \(expectedTitle); got '\(title.label)'"
    )
  }

  func selectFirstExistingBackground(
    in app: XCUIApplication,
    candidates: [String]
  ) -> String? {
    let preferencesRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesRoot
    )
    let preferencesWindow = window(in: app, containing: preferencesRoot)
    let collectionPicker = segmentedControl(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesBackgroundCollectionPicker
    )
    let nativeTab = button(in: app, title: "Native")

    XCTAssertTrue(collectionPicker.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(nativeTab.waitForExistence(timeout: Self.fastActionTimeout))

    for _ in 0..<4 where !nativeTab.isHittable {
      dragUp(in: app, element: preferencesWindow, distanceRatio: 0.18)
    }

    XCTAssertTrue(nativeTab.isHittable, "Native background tab never became hittable")
    nativeTab.tap()

    let nativeTileAppeared = waitUntil(timeout: Self.fastActionTimeout) {
      candidates.contains { candidate in
        self.element(
          in: app,
          identifier: HarnessMonitorUITestAccessibility.preferencesBackgroundTile(candidate)
        ).exists
      }
    }

    guard nativeTileAppeared else {
      return nil
    }

    for _ in 0..<2 {
      for candidate in candidates {
        let tile = element(
          in: app,
          identifier: HarnessMonitorUITestAccessibility.preferencesBackgroundTile(candidate)
        )
        if tile.exists, tile.isHittable {
          tile.tap()
          return candidate
        }
      }
      dragUp(in: app, element: mainWindow(in: app), distanceRatio: 0.22)
    }

    return nil
  }

  func tapBackgroundTile(in app: XCUIApplication, key: String) {
    let preferencesRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.preferencesRoot
    )
    let preferencesWindow = window(in: app, containing: preferencesRoot)
    let identifier = HarnessMonitorUITestAccessibility.preferencesBackgroundTile(key)

    for _ in 0..<2 {
      let tile = descendantElement(in: preferencesWindow, identifier: identifier)
      if tile.exists, tile.isHittable {
        tile.tap()
        return
      }

      dragUp(in: app, element: preferencesWindow, distanceRatio: 0.18)
    }

    XCTFail("Failed to tap background tile \(key)")
  }

  func closeSettings(in app: XCUIApplication, preferencesRoot: XCUIElement) {
    if !preferencesRoot.exists {
      return
    }

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !preferencesRoot.exists
      }
    )
  }

  func preferencesRootCount(in app: XCUIApplication) -> Int {
    app.descendants(matching: .any)
      .matching(identifier: HarnessMonitorUITestAccessibility.preferencesRoot)
      .count
  }

  func preferencesMetricValue(in element: XCUIElement, label: String) -> XCUIElement {
    element.descendants(matching: .staticText)
      .matching(NSPredicate(format: "label == %@", label))
      .firstMatch
  }
}
