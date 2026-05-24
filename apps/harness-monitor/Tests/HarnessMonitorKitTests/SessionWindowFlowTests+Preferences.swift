import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("Launch behavior defaults to restoring session windows")
  func launchBehaviorDefaultsToRestoringSessionWindows() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .restoreSessionWindows
    )
    defaults.userDefaults.set(
      HarnessMonitorLaunchBehavior.alwaysOpenRecent.rawValue,
      forKey: HarnessMonitorLaunchBehavior.storageKey
    )
    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .alwaysOpenRecent
    )
    defaults.userDefaults.set("legacy-garbage", forKey: HarnessMonitorLaunchBehavior.storageKey)
    #expect(
      HarnessMonitorLaunchBehavior.read(userDefaults: defaults.userDefaults)
        == .restoreSessionWindows
    )
  }

  @Test("Open Recent closes after picking a session by default")
  func openRecentCloseAfterPickDefaultsOnAndPersistsOff() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(OpenRecentCloseAfterPickDefaults.read(userDefaults: defaults.userDefaults))
    defaults.userDefaults.set(
      false,
      forKey: OpenRecentCloseAfterPickDefaults.storageKey
    )
    #expect(!OpenRecentCloseAfterPickDefaults.read(userDefaults: defaults.userDefaults))
    #expect(
      OpenRecentCloseAfterPickDefaults.storageKey
        == "harness.monitor.open-recent.close-after-pick"
    )
  }

  @Test("Pending decision banners default on and persist off")
  func pendingDecisionBannerDefaultsOnAndPersistsOff() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(SessionPendingDecisionBannerSettings.readEnabled(userDefaults: defaults.userDefaults))
    defaults.userDefaults.set(
      false,
      forKey: SessionPendingDecisionBannerSettings.enabledKey
    )
    #expect(!SessionPendingDecisionBannerSettings.readEnabled(userDefaults: defaults.userDefaults))
    #expect(
      SessionPendingDecisionBannerSettings.enabledKey
        == "harness.monitor.decisions.pending-banner-enabled"
    )
  }

  @Test("Pending decision banners in Focus mode default on and can be disabled separately")
  func pendingDecisionBannerFocusModeDefaultsOnAndPersistsOff() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(
      SessionPendingDecisionBannerSettings.readFocusModeEnabled(userDefaults: defaults.userDefaults)
    )
    defaults.userDefaults.set(
      false,
      forKey: SessionPendingDecisionBannerSettings.focusModeEnabledKey
    )
    #expect(
      !SessionPendingDecisionBannerSettings.readFocusModeEnabled(
        userDefaults: defaults.userDefaults)
    )
    #expect(
      SessionPendingDecisionBannerSettings.focusModeEnabledKey
        == "harness.monitor.decisions.pending-banner.focus-mode"
    )
  }

  @Test("Pending decision banner visibility respects the Focus mode setting")
  func pendingDecisionBannerVisibilityRespectsFocusModeSetting() throws {
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    #expect(
      SessionPendingDecisionBannerSettings.showsBanner(
        isFocusMode: false,
        userDefaults: defaults.userDefaults
      )
    )
    #expect(
      SessionPendingDecisionBannerSettings.showsBanner(
        isFocusMode: true,
        userDefaults: defaults.userDefaults
      )
    )

    defaults.userDefaults.set(
      false,
      forKey: SessionPendingDecisionBannerSettings.focusModeEnabledKey
    )
    #expect(
      SessionPendingDecisionBannerSettings.showsBanner(
        isFocusMode: false,
        userDefaults: defaults.userDefaults
      )
    )
    #expect(
      !SessionPendingDecisionBannerSettings.showsBanner(
        isFocusMode: true,
        userDefaults: defaults.userDefaults
      )
    )

    defaults.userDefaults.set(false, forKey: SessionPendingDecisionBannerSettings.enabledKey)
    #expect(
      !SessionPendingDecisionBannerSettings.showsBanner(
        isFocusMode: false,
        userDefaults: defaults.userDefaults
      )
    )
  }

  @Test("Startup registration defaults include pending decision banner settings")
  func startupRegistrationDefaultsIncludePendingDecisionBannerSettings() {
    let values = HarnessMonitorStartupRegistrationDefaults.values()

    #expect(values[SessionPendingDecisionBannerSettings.enabledKey] as? Bool == true)
    #expect(values[SessionPendingDecisionBannerSettings.focusModeEnabledKey] as? Bool == true)
  }
}
