import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsNotificationsUITests: HarnessMonitorUITestCase {
  func testNotificationsSettingsExposeNativeManualTestControls() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectNotificationsSection(in: app)

    let status = element(in: app, identifier: Accessibility.preferencesNotificationsStatus)
    let presetPicker = element(
      in: app,
      identifier: Accessibility.preferencesNotificationsPresetPicker
    )
    let categoryPicker = element(
      in: app,
      identifier: Accessibility.preferencesNotificationsCategoryPicker
    )
    let soundPicker = element(
      in: app,
      identifier: Accessibility.preferencesNotificationsSoundPicker
    )
    let attachmentPicker = element(
      in: app,
      identifier: Accessibility.preferencesNotificationsAttachmentPicker
    )
    let triggerPicker = element(
      in: app,
      identifier: Accessibility.preferencesNotificationsTriggerPicker
    )
    let sendButton = element(in: app, identifier: Accessibility.preferencesNotificationsSendButton)

    XCTAssertTrue(status.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(presetPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(categoryPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(soundPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(attachmentPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(triggerPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sendButton.waitForExistence(timeout: Self.actionTimeout))

    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(preferencesState.label.contains("section=notifications"))
    XCTAssertTrue(preferencesState.label.contains("preferencesChrome=native"))
  }
}
