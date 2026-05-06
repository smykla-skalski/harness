import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorSettingsNotificationsUITests: HarnessMonitorUITestCase {
  func testNotificationsSettingsExposeNativeManualTestControls() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    selectNotificationsSection(in: app)

    let status = element(in: app, identifier: Accessibility.settingsNotificationsStatus)
    let presetPicker = element(
      in: app,
      identifier: Accessibility.settingsNotificationsPresetPicker
    )
    let categoryPicker = element(
      in: app,
      identifier: Accessibility.settingsNotificationsCategoryPicker
    )
    let soundPicker = element(
      in: app,
      identifier: Accessibility.settingsNotificationsSoundPicker
    )
    let attachmentPicker = element(
      in: app,
      identifier: Accessibility.settingsNotificationsAttachmentPicker
    )
    let triggerPicker = element(
      in: app,
      identifier: Accessibility.settingsNotificationsTriggerPicker
    )
    let sendButton = element(in: app, identifier: Accessibility.settingsNotificationsSendButton)

    XCTAssertTrue(status.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(presetPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(categoryPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(soundPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(attachmentPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(triggerPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sendButton.waitForExistence(timeout: Self.actionTimeout))

    let settingsState = element(in: app, identifier: Accessibility.settingsState)
    XCTAssertTrue(settingsState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(settingsState.label.contains("section=notifications"))
    XCTAssertTrue(settingsState.label.contains("settingsChrome=native"))
  }
}
