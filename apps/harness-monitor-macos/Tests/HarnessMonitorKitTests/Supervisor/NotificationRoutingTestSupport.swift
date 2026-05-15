import Foundation
import UserNotifications

@testable import HarnessMonitorKit

actor NotificationRoutingResolveRecorder {
  struct Entry: Sendable {
    let id: String
    let outcome: DecisionOutcome
  }

  private(set) var entries: [Entry] = []

  func record(id: String, outcome: DecisionOutcome) {
    entries.append(Entry(id: id, outcome: outcome))
  }
}

final class NotificationRoutingTestCenter: HarnessMonitorUserNotificationCenter,
  @unchecked Sendable
{
  var delegate: UNUserNotificationCenterDelegate?
  private var pendingRequests: [UNNotificationRequest] = []
  private var categories: Set<UNNotificationCategory> = []

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    true
  }

  func notificationSettings() async -> UNNotificationSettings {
    fatalError("notificationSettings() should not be called in NotificationRoutingTests")
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] { pendingRequests }

  func deliveredNotifications() async -> [UNNotification] { [] }

  func notificationCategories() async -> Set<UNNotificationCategory> { categories }

  func add(_ request: UNNotificationRequest) async throws {
    pendingRequests.append(request)
  }

  func removeAllPendingNotificationRequests() {}

  func removeAllDeliveredNotifications() {}

  func setBadgeCount(_ newBadgeCount: Int) async throws {
    _ = newBadgeCount
  }

  func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
    self.categories = categories
  }
}

enum NotificationRoutingResponseFactory {
  static func make(
    request: UNNotificationRequest,
    actionIdentifier: String
  ) -> UNNotificationResponse {
    StubResponse(request: request, overrideActionIdentifier: actionIdentifier)
  }

  private final class StubNotification: UNNotification {
    private let requestValue: UNNotificationRequest

    init(request: UNNotificationRequest) {
      self.requestValue = request
      // swift-format-ignore: NeverForceUnwrap
      super.init(coder: Self.sharedDummyCoder())!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var request: UNNotificationRequest { requestValue }
    override var date: Date { Date() }

    private static func sharedDummyCoder() -> NSCoder {
      let archiver = NSKeyedArchiver(requiringSecureCoding: false)
      archiver.encode(Date(), forKey: "date")
      archiver.finishEncoding()
      do {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        return unarchiver
      } catch {
        preconditionFailure("Failed to build notification test coder: \(error)")
      }
    }
  }

  private final class StubResponse: UNNotificationResponse {
    private let overrideActionIdentifier: String
    private let notificationValue: StubNotification

    init(request: UNNotificationRequest, overrideActionIdentifier: String) {
      self.overrideActionIdentifier = overrideActionIdentifier
      self.notificationValue = StubNotification(request: request)
      // swift-format-ignore: NeverForceUnwrap
      super.init(coder: Self.sharedDummyCoder())!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override var actionIdentifier: String { overrideActionIdentifier }
    override var notification: UNNotification { notificationValue }

    private static func sharedDummyCoder() -> NSCoder {
      let archiver = NSKeyedArchiver(requiringSecureCoding: false)
      archiver.encode("", forKey: "actionIdentifier")
      archiver.finishEncoding()
      do {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        return unarchiver
      } catch {
        preconditionFailure("Failed to build notification test coder: \(error)")
      }
    }
  }
}

@MainActor
func makeNotificationRoutingController() -> HarnessMonitorUserNotificationController {
  HarnessMonitorUserNotificationController(center: NotificationRoutingTestCenter())
}

func makeNotificationRoutingSupervisorRequest(
  decisionID: String,
  severity: DecisionSeverity
) async throws -> UNNotificationRequest {
  try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
    severity: severity,
    summary: "sample summary",
    decisionID: decisionID
  )
}
