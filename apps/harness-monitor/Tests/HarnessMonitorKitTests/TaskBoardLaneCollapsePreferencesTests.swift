import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane collapse preferences")
struct TaskBoardLaneCollapsePreferencesTests {
  @Test("Default empty lanes collapse automatically")
  func defaultEmptyLanesCollapseAutomatically() {
    #expect(
      TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .inReview,
        contentCount: 0,
        rawValue: TaskBoardLaneCollapsePreferences.emptyRawValue
      )
    )
    #expect(
      !TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .inReview,
        contentCount: 1,
        rawValue: TaskBoardLaneCollapsePreferences.emptyRawValue
      )
    )
  }

  @Test("Manual overrides persist")
  func manualOverridesPersist() throws {
    let suiteName = "TaskBoardLaneCollapsePreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let expandedRawValue = TaskBoardLaneCollapsePreferences.toggledRawValue(
      lane: .inReview,
      contentCount: 0,
      rawValue: TaskBoardLaneCollapsePreferences.emptyRawValue
    )
    #expect(
      !TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .inReview,
        contentCount: 0,
        rawValue: expandedRawValue
      )
    )

    TaskBoardLaneCollapsePreferences.save(
      TaskBoardLaneCollapsePreferences.overrides(from: expandedRawValue),
      to: userDefaults
    )
    #expect(TaskBoardLaneCollapsePreferences.load(from: userDefaults)[.inReview] == false)

    let collapsedRawValue = TaskBoardLaneCollapsePreferences.toggledRawValue(
      lane: .inReview,
      contentCount: 0,
      rawValue: expandedRawValue
    )
    TaskBoardLaneCollapsePreferences.save(
      TaskBoardLaneCollapsePreferences.overrides(from: collapsedRawValue),
      to: userDefaults
    )

    #expect(TaskBoardLaneCollapsePreferences.load(from: userDefaults)[.inReview] == true)
    #expect(
      TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .inReview,
        contentCount: 3,
        rawValue: userDefaults.string(forKey: TaskBoardLaneCollapsePreferences.storageKey) ?? ""
      )
    )
  }
}
