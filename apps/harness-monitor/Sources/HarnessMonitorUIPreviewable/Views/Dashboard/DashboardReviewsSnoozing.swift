import HarnessMonitorKit
import SwiftUI

public enum DashboardReviewsSnoozeCondition: Codable, Equatable, Sendable {
  case untilDate(Date)
  case indefinitely
  case untilActivity(lastSeenUpdatedAt: String)

  public func isExpired(currentDate: Date, currentUpdatedAt: String) -> Bool {
    switch self {
    case .untilDate(let date):
      return currentDate >= date
    case .indefinitely:
      return false
    case .untilActivity(let lastSeenUpdatedAt):
      return currentUpdatedAt != lastSeenUpdatedAt
    }
  }
}

public struct DashboardReviewsSnoozedPullRequests: Codable, Equatable, Sendable {
  public static let storageKey = "dashboard.reviews.snoozed-pull-requests"

  public var snoozed: [String: DashboardReviewsSnoozeCondition] = [:]

  public init(snoozed: [String: DashboardReviewsSnoozeCondition] = [:]) {
    self.snoozed = snoozed
  }

  public init(storedValue: String) {
    self = Self.decode(from: storedValue)
  }

  public var encodedString: String {
    DashboardReviewsStorageCodec.encodeToString(self)
  }

  public func condition(for pullRequestID: String) -> DashboardReviewsSnoozeCondition? {
    snoozed[pullRequestID]
  }

  public func isSnoozed(_ pullRequestID: String, currentDate: Date, currentUpdatedAt: String) -> Bool {
    guard let condition = snoozed[pullRequestID] else { return false }
    return !condition.isExpired(currentDate: currentDate, currentUpdatedAt: currentUpdatedAt)
  }

  @discardableResult
  public mutating func snooze(_ pullRequestID: String, condition: DashboardReviewsSnoozeCondition) -> Bool {
    snoozed[pullRequestID] = condition
    return true
  }

  @discardableResult
  public mutating func unsnooze(_ pullRequestID: String) -> Bool {
    guard snoozed.keys.contains(pullRequestID) else { return false }
    snoozed.removeValue(forKey: pullRequestID)
    return true
  }

  /// Remove all expired snoozes to avoid unbounded growth over time.
  public mutating func pruneExpired(currentDate: Date = .now, currentItems: [ReviewItem]) {
    let currentItemsMap = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.pullRequestID, $0.updatedAt) })
    
    for (id, condition) in snoozed {
      // If the PR no longer exists in current payload, we could remove it, but let's just 
      // check expiry if we have its updatedAt. For date/indefinite, we don't need updatedAt.
      let currentUpdatedAt = currentItemsMap[id] ?? ""
      
      // If it is an activity based snooze and the PR is gone, we might just prune it, 
      // or we can just leave it until it reappears. But pruning if expired is safe.
      if condition.isExpired(currentDate: currentDate, currentUpdatedAt: currentUpdatedAt) {
        // Wait, if it's activity based, and currentUpdatedAt is empty (PR not in list),
        // we probably shouldn't expire it just because it temporarily disappeared.
        // So only prune if we have the PR or if it's a date-based expiry.
        switch condition {
        case .untilDate(let date):
          if currentDate >= date {
            snoozed.removeValue(forKey: id)
          }
        case .indefinitely:
          break
        case .untilActivity(let lastSeenUpdatedAt):
          if currentUpdatedAt != "", currentUpdatedAt != lastSeenUpdatedAt {
            snoozed.removeValue(forKey: id)
          }
        }
      }
    }
  }

  public static func decode(from string: String) -> Self {
    DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}
