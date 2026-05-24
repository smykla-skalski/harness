import Foundation
import HarnessMonitorCore
@preconcurrency import UserNotifications

protocol MobileNotificationScheduling: Sendable {
  func requestAuthorization() async -> Bool
  func schedule(_ requests: [MobileNotificationRequest]) async -> Set<String>
}

actor LiveMobileNotificationScheduler: MobileNotificationScheduling {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func requestAuthorization() async -> Bool {
    do {
      return try await center.requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      return false
    }
  }

  func schedule(_ requests: [MobileNotificationRequest]) async -> Set<String> {
    guard !requests.isEmpty else {
      return []
    }
    registerCategories()
    let allowed = await notificationsAreAllowed()
    if !allowed {
      let granted = await requestAuthorization()
      guard granted else {
        return []
      }
    }
    var scheduledRequestIDs: Set<String> = []
    for request in requests {
      do {
        try await center.add(notificationRequest(for: request))
        scheduledRequestIDs.insert(request.id)
      } catch {
        continue
      }
    }
    return scheduledRequestIDs
  }

  private func notificationsAreAllowed() async -> Bool {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .ephemeral, .provisional:
      return true
    case .denied, .notDetermined:
      return false
    @unknown default:
      return false
    }
  }

  private func registerCategories() {
    let categories = Set(
      MobileNotificationCategory.allCases.map { category in
        UNNotificationCategory(
          identifier: category.notificationIdentifier,
          actions: [],
          intentIdentifiers: [],
          options: []
        )
      }
    )
    center.setNotificationCategories(categories)
  }

  private func notificationRequest(
    for request: MobileNotificationRequest
  ) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.categoryIdentifier = request.category.notificationIdentifier
    content.threadIdentifier = "station.\(request.stationID)"
    content.interruptionLevel = request.interruption.unNotificationInterruptionLevel
    content.sound = .default
    content.userInfo = [
      "stationID": request.stationID,
      "category": request.category.rawValue,
      "createdAt": request.createdAt.timeIntervalSince1970,
    ]
    return UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
  }
}

extension MobileNotificationCategory {
  fileprivate var notificationIdentifier: String {
    "io.harnessmonitor.mobile.notification.\(rawValue)"
  }
}

extension MobileNotificationInterruption {
  fileprivate var unNotificationInterruptionLevel: UNNotificationInterruptionLevel {
    switch self {
    case .passive: .passive
    case .active: .active
    case .timeSensitive: .timeSensitive
    }
  }
}
