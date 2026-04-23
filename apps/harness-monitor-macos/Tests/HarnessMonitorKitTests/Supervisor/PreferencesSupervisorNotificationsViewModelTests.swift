import UserNotifications
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PreferencesSupervisorNotificationsViewModelTests: XCTestCase {
  func test_defaultsMatchExpectedSeverityMatrix() {
    let viewModel = PreferencesSupervisorNotificationsViewModel(
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
    let viewModel = PreferencesSupervisorNotificationsViewModel(userDefaults: userDefaults)

    viewModel.setEnabled(false, channel: .sound, for: .critical)
    viewModel.setEnabled(false, channel: .badge, for: .needsUser)

    let reloaded = PreferencesSupervisorNotificationsViewModel(userDefaults: userDefaults)
    XCTAssertFalse(reloaded.isEnabled(.sound, for: .critical))
    XCTAssertFalse(reloaded.isEnabled(.badge, for: .needsUser))
  }

  func test_foregroundPresentationOptionsReflectEnabledChannels() {
    var preferences = SupervisorNotificationPreferences()
    preferences.setEnabled(false, channel: .banner, for: .warn)
    preferences.setEnabled(true, channel: .badge, for: .warn)

    let options = preferences.foregroundPresentationOptions(for: .warn)

    XCTAssertFalse(options.contains(.banner))
    XCTAssertTrue(options.contains(.list))
    XCTAssertTrue(options.contains(.sound))
    XCTAssertTrue(options.contains(.badge))
  }

  func test_requestSoundAndDeliveryFollowPreferences() {
    var preferences = SupervisorNotificationPreferences()

    preferences.setEnabled(false, channel: .sound, for: .critical)
    preferences.setEnabled(false, channel: .banner, for: .info)
    preferences.setEnabled(false, channel: .notificationCenter, for: .info)
    preferences.setEnabled(false, channel: .lockScreen, for: .info)

    XCTAssertNil(preferences.requestSound(for: .critical))
    XCTAssertFalse(preferences.allowsAnyDelivery(for: .info))
  }

  private func makeUserDefaults() -> UserDefaults {
    let suiteName = "PreferencesSupervisorNotificationsViewModelTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    return userDefaults
  }
}
