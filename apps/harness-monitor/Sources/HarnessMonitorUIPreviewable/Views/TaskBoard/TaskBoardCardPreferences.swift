import Foundation
import SwiftUI

enum TaskBoardCardPreferences {
  static let priorityBadgeVisibilityStorageKey =
    "harness.task-board.cards.priority-badge-visible.v1"
  static let defaultShowsPriorityBadge = true

  static func showsPriorityBadge(from userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: priorityBadgeVisibilityStorageKey) != nil else {
      return defaultShowsPriorityBadge
    }
    return userDefaults.bool(forKey: priorityBadgeVisibilityStorageKey)
  }

  static func setShowsPriorityBadge(
    _ isVisible: Bool,
    in userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isVisible, forKey: priorityBadgeVisibilityStorageKey)
  }
}

extension EnvironmentValues {
  @Entry var taskBoardShowsPriorityBadge = TaskBoardCardPreferences.defaultShowsPriorityBadge
}
