import UserNotifications

public protocol HarnessMonitorUserNotificationCenter: AnyObject {
  var delegate: UNUserNotificationCenterDelegate? { get set }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func notificationSettings() async -> UNNotificationSettings
  func pendingNotificationRequests() async -> [UNNotificationRequest]
  func deliveredNotifications() async -> [UNNotification]
  func notificationCategories() async -> Set<UNNotificationCategory>
  func add(_ request: UNNotificationRequest) async throws
  func removeAllPendingNotificationRequests()
  func removeAllDeliveredNotifications()
  func setBadgeCount(_ newBadgeCount: Int) async throws
  func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: HarnessMonitorUserNotificationCenter {}

final class HarnessMonitorUserNotificationCenterBox: @unchecked Sendable {
  let base: any HarnessMonitorUserNotificationCenter

  init(_ base: any HarnessMonitorUserNotificationCenter) {
    self.base = base
  }
}
