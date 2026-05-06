import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsVoiceUITests: HarnessMonitorUITestCase {
  func testVoiceSettingsExposeSharedConfigurationControlsAndPersistAcrossReopeningSettings()
    throws
  {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": "dark"]
    )

    openSettings(in: app)

    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    let voiceRoot = element(in: app, identifier: Accessibility.settingsVoiceRoot)

    XCTAssertTrue(settingsRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))

    selectVoiceSection(in: app)

    XCTAssertTrue(voiceRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      editableField(in: app, identifier: Accessibility.settingsVoiceLocaleField).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceLocalePicker).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceLocalDaemonToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceAgentBridgeToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceRemoteProcessorToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceInsertionModePicker).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceAudioChunksToggle).exists
    )
    XCTAssertTrue(
      editableField(
        in: app,
        identifier: Accessibility.settingsVoicePendingAudioField
      ).exists
    )
    XCTAssertTrue(
      editableField(
        in: app,
        identifier: Accessibility.settingsVoicePendingTranscriptField
      ).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.settingsVoiceStatus).exists
    )
    XCTAssertEqual(
      settingsState.label,
      settingsStateLabel(.voice(mode: "dark"))
    )

    let remoteToggle = element(
      in: app, identifier: Accessibility.settingsVoiceRemoteProcessorToggle)
    XCTAssertTrue(remoteToggle.waitForExistence(timeout: Self.actionTimeout))
    if (remoteToggle.value as? String) != "1" {
      tapElement(in: app, identifier: Accessibility.settingsVoiceRemoteProcessorToggle)
    }

    let remoteURLField = editableField(
      in: app,
      identifier: Accessibility.settingsVoiceRemoteProcessorURLField
    )
    XCTAssertTrue(remoteURLField.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.settingsVoiceRemoteProcessorURLField)
    app.typeText("https://processor.example/voice")
    app.typeKey(.tab, modifierFlags: [])

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.settingsVoiceInsertionModePicker,
      optionTitle: "Auto Insert"
    )

    closeSettings(in: app, settingsRoot: settingsRoot)
    openSettings(in: app)
    selectVoiceSection(in: app)

    let reopenedRemoteURLField = editableField(
      in: app,
      identifier: Accessibility.settingsVoiceRemoteProcessorURLField
    )
    let insertionModePicker = popUpButton(
      in: app,
      identifier: Accessibility.settingsVoiceInsertionModePicker
    )

    XCTAssertEqual(
      reopenedRemoteURLField.value as? String,
      "https://processor.example/voice"
    )
    XCTAssertEqual(insertionModePicker.value as? String, "Auto Insert")
  }
}
