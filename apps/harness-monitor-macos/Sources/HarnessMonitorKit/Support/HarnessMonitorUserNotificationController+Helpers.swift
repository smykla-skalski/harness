import Foundation
import UserNotifications

final class PreviewHarnessMonitorUserNotificationCenter:
  HarnessMonitorUserNotificationCenter,
  @unchecked Sendable
{
  var delegate: UNUserNotificationCenterDelegate?

  private var pendingRequests: [UNNotificationRequest]
  private var categories: Set<UNNotificationCategory>
  private var badgeCount = 0

  init(
    pendingRequests: [UNNotificationRequest] = [],
    categories: Set<UNNotificationCategory> = []
  ) {
    self.pendingRequests = pendingRequests
    self.categories = categories
  }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    _ = options
    return true
  }

  func notificationSettings() async -> UNNotificationSettings {
    fatalError("Preview center does not vend system notification settings directly.")
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] {
    pendingRequests
  }

  func deliveredNotifications() async -> [UNNotification] {
    []
  }

  func notificationCategories() async -> Set<UNNotificationCategory> {
    categories
  }

  func add(_ request: UNNotificationRequest) async throws {
    pendingRequests.append(request)
  }

  func removeAllPendingNotificationRequests() {
    pendingRequests.removeAll()
  }

  func removeAllDeliveredNotifications() {}

  func setBadgeCount(_ newBadgeCount: Int) async throws {
    badgeCount = newBadgeCount
  }

  func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
    self.categories = categories
  }
}

extension HarnessMonitorNotificationSettingsSnapshot {
  public init(settings: UNNotificationSettings) {
    self.authorizationStatus = Self.label(for: settings.authorizationStatus)
    self.alertSetting = Self.label(for: settings.alertSetting)
    self.soundSetting = Self.label(for: settings.soundSetting)
    self.badgeSetting = Self.label(for: settings.badgeSetting)
    self.notificationCenterSetting = Self.label(for: settings.notificationCenterSetting)
    self.lockScreenSetting = Self.label(for: settings.lockScreenSetting)
    self.alertStyle = Self.label(for: settings.alertStyle)
    self.showPreviews = Self.label(for: settings.showPreviewsSetting)
    self.timeSensitiveSetting = Self.label(for: settings.timeSensitiveSetting)
    self.scheduledDeliverySetting = Self.label(for: settings.scheduledDeliverySetting)
    self.directMessagesSetting = Self.label(for: settings.directMessagesSetting)
    self.providesAppNotificationSettings = settings.providesAppNotificationSettings
  }

  private static func label(for status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not determined"
    case .denied: "denied"
    case .authorized: "authorized"
    case .provisional: "provisional"
    @unknown default: "unknown"
    }
  }

  private static func label(for setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported: "not supported"
    case .disabled: "disabled"
    case .enabled: "enabled"
    @unknown default: "unknown"
    }
  }

  private static func label(for style: UNAlertStyle) -> String {
    switch style {
    case .none: "none"
    case .banner: "banner"
    case .alert: "alert"
    @unknown default: "unknown"
    }
  }

  private static func label(for setting: UNShowPreviewsSetting) -> String {
    switch setting {
    case .always: "always"
    case .whenAuthenticated: "when authenticated"
    case .never: "never"
    @unknown default: "unknown"
    }
  }
}
