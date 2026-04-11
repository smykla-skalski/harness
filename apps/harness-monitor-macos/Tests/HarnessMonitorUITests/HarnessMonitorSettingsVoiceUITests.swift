import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsVoiceUITests: HarnessMonitorUITestCase {
  func testVoiceSettingsExposeSharedConfigurationControlsAndPersistAcrossReopeningPreferences()
    throws
  {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_THEME_MODE_OVERRIDE": "dark"]
    )

    openSettings(in: app)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let voiceRoot = element(in: app, identifier: Accessibility.preferencesVoiceRoot)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))

    selectVoiceSection(in: app)

    XCTAssertTrue(voiceRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      editableField(in: app, identifier: Accessibility.preferencesVoiceLocaleField).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceLocalePicker).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceLocalDaemonToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceAgentBridgeToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceRemoteProcessorToggle).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceInsertionModePicker).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceAudioChunksToggle).exists
    )
    XCTAssertTrue(
      editableField(
        in: app,
        identifier: Accessibility.preferencesVoicePendingAudioChunkLimitField
      ).exists
    )
    XCTAssertTrue(
      editableField(
        in: app,
        identifier: Accessibility.preferencesVoicePendingTranscriptLimitField
      ).exists
    )
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.preferencesVoiceStatus).exists
    )
    XCTAssertEqual(
      preferencesState.label,
      preferencesStateLabel(.voice(mode: "dark"))
    )

    let remoteToggle = element(in: app, identifier: Accessibility.preferencesVoiceRemoteProcessorToggle)
    XCTAssertTrue(remoteToggle.waitForExistence(timeout: Self.actionTimeout))
    if (remoteToggle.value as? String) != "1" {
      tapElement(in: app, identifier: Accessibility.preferencesVoiceRemoteProcessorToggle)
    }

    let remoteURLField = editableField(
      in: app,
      identifier: Accessibility.preferencesVoiceRemoteProcessorURLField
    )
    XCTAssertTrue(remoteURLField.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.preferencesVoiceRemoteProcessorURLField)
    app.typeText("https://processor.example/voice")
    app.typeKey(.tab, modifierFlags: [])

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.preferencesVoiceInsertionModePicker,
      optionTitle: "Auto Insert"
    )

    closeSettings(in: app, preferencesRoot: preferencesRoot)
    openSettings(in: app)
    selectVoiceSection(in: app)

    let reopenedRemoteURLField = editableField(
      in: app,
      identifier: Accessibility.preferencesVoiceRemoteProcessorURLField
    )
    let insertionModePicker = popUpButton(
      in: app,
      identifier: Accessibility.preferencesVoiceInsertionModePicker
    )

    XCTAssertEqual(
      reopenedRemoteURLField.value as? String,
      "https://processor.example/voice"
    )
    XCTAssertEqual(insertionModePicker.value as? String, "Auto Insert")
  }
}
