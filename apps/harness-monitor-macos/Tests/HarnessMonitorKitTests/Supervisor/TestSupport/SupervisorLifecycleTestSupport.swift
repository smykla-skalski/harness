import UserNotifications
import XCTest

@testable import HarnessMonitorKit

actor TickRecorder {
  private(set) var count = 0

  func recordTick() {
    count += 1
  }
}

@MainActor
final class PendingDecisionsBadgeSyncRecorder {
  private(set) var counts: [Int] = []

  func record(_ count: Int) {
    counts.append(count)
  }
}

final class RecordingNotificationCenter: HarnessMonitorUserNotificationCenter, @unchecked Sendable {
  var delegate: UNUserNotificationCenterDelegate?
  private(set) var badgeCounts: [Int] = []

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

  func notificationSettings() async -> UNNotificationSettings {
    fatalError("notificationSettings() is not used in these badge-sync tests")
  }

  func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }

  func deliveredNotifications() async -> [UNNotification] { [] }

  func notificationCategories() async -> Set<UNNotificationCategory> { [] }

  func add(_ request: UNNotificationRequest) async throws {}

  func removeAllPendingNotificationRequests() {}

  func removeAllDeliveredNotifications() {}

  func setBadgeCount(_ newBadgeCount: Int) async throws { badgeCounts.append(newBadgeCount) }

  func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
}

func waitForBadgeCounts(
  _ expected: [Int],
  center: RecordingNotificationCenter,
  timeout: Duration = .seconds(1)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while center.badgeCounts != expected {
    if clock.now >= deadline {
      XCTFail("Timed out waiting for badge counts \(expected); got \(center.badgeCounts)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor
func waitForPendingDecisionBadgeCounts(
  _ expected: [Int],
  recorder: PendingDecisionsBadgeSyncRecorder,
  timeout: Duration = .seconds(1)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while recorder.counts != expected {
    if clock.now >= deadline {
      XCTFail(
        "Timed out waiting for pending decision badge counts \(expected); got \(recorder.counts)"
      )
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
