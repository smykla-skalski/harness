import UserNotifications
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SettingsSupervisorNotificationsViewModelTests: XCTestCase {
  func test_defaultsMatchExpectedSeverityMatrix() {
    let viewModel = SettingsSupervisorNotificationsViewModel(
      userDefaults: makeUserDefaults()
    )

    XCTAssertTrue(viewModel.isEnabled(.banner, for: .info))
    XCTAssertTrue(viewModel.isEnabled(.notificationCenter, for: .warn))
    XCTAssertFalse(viewModel.isEnabled(.sound, for: .info))
    XCTAssertTrue(viewModel.isEnabled(.sound, for: .critical))
    XCTAssertTrue(viewModel.isEnabled(.badge, for: .needsUser))
  }

  func test_setEnabledPersistsAndReloads() {
    let userDefaults = makeUserDefaults()
    let viewModel = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)

    viewModel.setEnabled(false, channel: .sound, for: .critical)
    viewModel.setEnabled(false, channel: .badge, for: .needsUser)

    let reloaded = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)
    XCTAssertFalse(reloaded.isEnabled(.sound, for: .critical))
    XCTAssertFalse(reloaded.isEnabled(.badge, for: .needsUser))
  }

  func test_foregroundPresentationOptionsReflectEnabledChannels() {
    var settings = SupervisorNotificationSettings()
    settings.setEnabled(false, channel: .banner, for: .warn)
    settings.setEnabled(true, channel: .badge, for: .warn)

    let options = settings.foregroundPresentationOptions(for: .warn)

    XCTAssertFalse(options.contains(.banner))
    XCTAssertTrue(options.contains(.list))
    XCTAssertTrue(options.contains(.sound))
    XCTAssertTrue(options.contains(.badge))
  }

  func test_requestSoundAndDeliveryFollowSettings() {
    var settings = SupervisorNotificationSettings()

    settings.setEnabled(false, channel: .sound, for: .critical)
    settings.setEnabled(false, channel: .banner, for: .info)
    settings.setEnabled(false, channel: .notificationCenter, for: .info)
    settings.setEnabled(false, channel: .lockScreen, for: .info)

    XCTAssertNil(settings.requestSound(for: .critical))
    XCTAssertFalse(settings.allowsAnyDelivery(for: .info))
  }

  func test_setAllowedFalseClearsAllChannelsForSeverity() {
    let userDefaults = makeUserDefaults()
    let viewModel = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)
    XCTAssertTrue(viewModel.allowsAny(for: .critical))

    viewModel.setAllowed(false, for: .critical)

    XCTAssertFalse(viewModel.allowsAny(for: .critical))
    for channel in SupervisorNotificationChannel.allCases {
      XCTAssertFalse(viewModel.isEnabled(channel, for: .critical))
    }
    let reloaded = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)
    XCTAssertFalse(reloaded.allowsAny(for: .critical))
    XCTAssertTrue(reloaded.allowsAny(for: .warn))
  }

  func test_setAllowedTrueRestoresSeverityDefaults() {
    let userDefaults = makeUserDefaults()
    let viewModel = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)
    viewModel.setAllowed(false, for: .needsUser)
    XCTAssertFalse(viewModel.allowsAny(for: .needsUser))

    viewModel.setAllowed(true, for: .needsUser)

    let defaults = SupervisorNotificationSettings.defaultChannels(for: .needsUser)
    for channel in SupervisorNotificationChannel.allCases {
      XCTAssertEqual(
        viewModel.isEnabled(channel, for: .needsUser),
        defaults.contains(channel),
        "mismatch for \(channel)"
      )
    }
  }

  func test_verboseToolCallAnnouncementsDefaultAndPersistence() {
    let userDefaults = makeUserDefaults()
    let viewModel = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)

    XCTAssertFalse(viewModel.verboseToolCallAnnouncementsEnabled)

    viewModel.setVerboseToolCallAnnouncementsEnabled(true)

    let reloaded = SettingsSupervisorNotificationsViewModel(userDefaults: userDefaults)
    XCTAssertTrue(reloaded.verboseToolCallAnnouncementsEnabled)
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "SettingsSupervisorNotificationsViewModelTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    return userDefaults
  }
}
