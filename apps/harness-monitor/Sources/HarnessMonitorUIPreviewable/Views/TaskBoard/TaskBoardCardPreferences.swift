import Foundation
import SwiftUI

enum TaskBoardCardPreferences {
  static let priorityBadgeVisibilityStorageKey =
    "harness.task-board.cards.priority-badge-visible.v1"
  static let approvalBadgeVisibilityStorageKey =
    "harness.task-board.cards.approval-badge-visible.v1"
  static let fullRepositoryNamesStorageKey =
    "harness.task-board.cards.full-repository-names.v1"
  static let defaultShowsPriorityBadge = true
  static let defaultShowsApprovalBadge = true
  static let defaultAlwaysShowsFullRepositoryNames = false

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

  static func showsApprovalBadge(from userDefaults: UserDefaults = .standard) -> Bool {
    guard userDefaults.object(forKey: approvalBadgeVisibilityStorageKey) != nil else {
      return defaultShowsApprovalBadge
    }
    return userDefaults.bool(forKey: approvalBadgeVisibilityStorageKey)
  }

  static func setShowsApprovalBadge(
    _ isVisible: Bool,
    in userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(isVisible, forKey: approvalBadgeVisibilityStorageKey)
  }

  static func alwaysShowsFullRepositoryNames(
    from userDefaults: UserDefaults = .standard
  ) -> Bool {
    guard userDefaults.object(forKey: fullRepositoryNamesStorageKey) != nil else {
      return defaultAlwaysShowsFullRepositoryNames
    }
    return userDefaults.bool(forKey: fullRepositoryNamesStorageKey)
  }

  static func setAlwaysShowsFullRepositoryNames(
    _ alwaysShowsFullRepositoryNames: Bool,
    in userDefaults: UserDefaults = .standard
  ) {
    userDefaults.set(alwaysShowsFullRepositoryNames, forKey: fullRepositoryNamesStorageKey)
  }
}

extension EnvironmentValues {
  @Entry var taskBoardShowsPriorityBadge = TaskBoardCardPreferences.defaultShowsPriorityBadge
  @Entry var taskBoardShowsApprovalBadge = TaskBoardCardPreferences.defaultShowsApprovalBadge
  @Entry var taskBoardAlwaysShowsFullRepositoryNames =
    TaskBoardCardPreferences.defaultAlwaysShowsFullRepositoryNames
}

private struct TaskBoardCardPreferencesModifier: ViewModifier {
  let projectLabelResolver: TaskBoardProjectLabelResolver
  @AppStorage(TaskBoardCardPreferences.priorityBadgeVisibilityStorageKey)
  private var showsPriorityBadge = TaskBoardCardPreferences.defaultShowsPriorityBadge
  @AppStorage(TaskBoardCardPreferences.approvalBadgeVisibilityStorageKey)
  private var showsApprovalBadge = TaskBoardCardPreferences.defaultShowsApprovalBadge
  @AppStorage(TaskBoardCardPreferences.fullRepositoryNamesStorageKey)
  private var alwaysShowsFullRepositoryNames =
    TaskBoardCardPreferences.defaultAlwaysShowsFullRepositoryNames

  func body(content: Content) -> some View {
    content
      .environment(\.taskBoardShowsPriorityBadge, showsPriorityBadge)
      .environment(\.taskBoardShowsApprovalBadge, showsApprovalBadge)
      .environment(
        \.taskBoardAlwaysShowsFullRepositoryNames,
        alwaysShowsFullRepositoryNames
      )
      .environment(\.taskBoardProjectLabelResolver, projectLabelResolver)
  }
}

extension View {
  func taskBoardCardPreferences(
    projectLabelResolver: TaskBoardProjectLabelResolver
  ) -> some View {
    modifier(TaskBoardCardPreferencesModifier(projectLabelResolver: projectLabelResolver))
  }
}
