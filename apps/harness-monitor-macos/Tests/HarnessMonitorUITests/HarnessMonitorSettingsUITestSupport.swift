import XCTest

enum HarnessMonitorSettingsUITestKeys {
  static let textSizeOverride = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"
  static let sidebarSessionRowDisplayModeOverride =
    "HARNESS_MONITOR_SIDEBAR_SESSION_ROW_DISPLAY_MODE_OVERRIDE"
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

extension HarnessMonitorUITestCase {
  func selectAppearanceSection(in app: XCUIApplication) {
    selectSettingsSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsAppearanceSection,
      expectedTitle: "Appearance"
    )
  }

  func selectNotificationsSection(in app: XCUIApplication) {
    selectSettingsSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsNotificationsSection,
      expectedTitle: "Notifications"
    )
  }

  func selectVoiceSection(in app: XCUIApplication) {
    selectSettingsSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsVoiceSection,
      expectedTitle: "Voice"
    )
  }

  func selectSupervisorSection(in app: XCUIApplication) {
    selectSettingsSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsSupervisorSection,
      expectedTitle: "Supervisor"
    )
  }

  func selectSupervisorNotificationsPane(in app: XCUIApplication) {
    let notificationsPane = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsSupervisorPane("notifications")
    )
    if notificationsPane.exists {
      return
    }

    selectSupervisorSection(in: app)

    let panePicker = segmentedControl(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsSupervisorPane("pane-picker")
    )
    XCTAssertTrue(
      panePicker.waitForExistence(timeout: Self.actionTimeout),
      "Supervisor pane picker should appear in the toolbar"
    )

    tapButton(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.segmentedOption(
        HarnessMonitorUITestAccessibility.settingsSupervisorPane("pane-picker"),
        option: "Notifications"
      )
    )
    XCTAssertTrue(
      waitForElement(notificationsPane, timeout: Self.actionTimeout),
      "Supervisor Notifications pane should appear after selecting the toolbar segment"
    )
  }

  func selectGeneralSection(in app: XCUIApplication) {
    selectSettingsSection(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsGeneralSection,
      expectedTitle: "General"
    )
  }

  func selectSettingsSection(
    in app: XCUIApplication,
    identifier: String,
    expectedTitle: String
  ) {
    let title = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsTitle
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
      "Settings title did not switch to \(expectedTitle); got '\(title.label)'"
    )
  }

  func selectFirstExistingBackground(
    in app: XCUIApplication,
    candidates: [String]
  ) -> String? {
    let settingsRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsRoot
    )
    let settingsWindow = window(in: app, containing: settingsRoot)
    let collectionPicker = segmentedControl(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsBackgroundCollectionPicker
    )
    let nativeTab = button(in: app, title: "Native")

    XCTAssertTrue(collectionPicker.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(nativeTab.waitForExistence(timeout: Self.fastActionTimeout))

    for _ in 0..<4 where !nativeTab.isHittable {
      dragUp(in: app, element: settingsWindow, distanceRatio: 0.18)
    }

    XCTAssertTrue(nativeTab.isHittable, "Native background tab never became hittable")
    nativeTab.tap()

    let nativeTileAppeared = waitUntil(timeout: Self.fastActionTimeout) {
      candidates.contains { candidate in
        self.element(
          in: app,
          identifier: HarnessMonitorUITestAccessibility.settingsBackgroundTile(candidate)
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
          identifier: HarnessMonitorUITestAccessibility.settingsBackgroundTile(candidate)
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
    let settingsRoot = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.settingsRoot
    )
    let settingsWindow = window(in: app, containing: settingsRoot)
    let identifier = HarnessMonitorUITestAccessibility.settingsBackgroundTile(key)

    for _ in 0..<2 {
      let tile = descendantElement(in: settingsWindow, identifier: identifier)
      if tile.exists, tile.isHittable {
        tile.tap()
        return
      }

      dragUp(in: app, element: settingsWindow, distanceRatio: 0.18)
    }

    XCTFail("Failed to tap background tile \(key)")
  }

  func closeSettings(in app: XCUIApplication, settingsRoot: XCUIElement) {
    if !settingsRoot.exists {
      return
    }

    app.typeKey("w", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        !settingsRoot.exists
      }
    )
  }

  func settingsRootCount(in app: XCUIApplication) -> Int {
    app.descendants(matching: .any)
      .matching(identifier: HarnessMonitorUITestAccessibility.settingsRoot)
      .count
  }

  func settingsMetricValue(in element: XCUIElement, label: String) -> XCUIElement {
    element.descendants(matching: .staticText)
      .matching(NSPredicate(format: "label == %@", label))
      .firstMatch
  }
}
