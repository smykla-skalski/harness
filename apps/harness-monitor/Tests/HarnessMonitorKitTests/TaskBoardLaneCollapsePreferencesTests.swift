import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane collapse preferences")
@MainActor
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

  @Test("Legacy Umbrella override loads as Backlog and writes canonically")
  func legacyUmbrellaOverrideLoadsAsBacklogAndWritesCanonically() {
    let overrides = TaskBoardLaneCollapsePreferences.overrides(
      from: #"{"umbrella":false}"#
    )
    let canonicalRawValue = TaskBoardLaneCollapsePreferences.rawValue(for: overrides)

    #expect(overrides[.backlog] == false)
    #expect(canonicalRawValue == #"{"backlog":false}"#)
  }

  @Test("Repeated parses of the same raw value return equal results")
  func repeatedParsesOfSameRawValueReturnEqualResults() {
    let rawValue = #"{"inReview":true,"testing":false}"#

    let first = TaskBoardLaneCollapsePreferences.overrides(from: rawValue)
    let second = TaskBoardLaneCollapsePreferences.overrides(from: rawValue)

    #expect(first == second)
  }

  @Test("Repeated raw value does not re-invoke the decoder")
  func repeatedRawValueDoesNotReinvokeDecoder() {
    let rawValue = #"{"planning":true}"#

    _ = TaskBoardLaneCollapsePreferences.overrides(from: rawValue)
    let countAfterFirstParse = TaskBoardLaneCollapsePreferences.decodeCount

    _ = TaskBoardLaneCollapsePreferences.overrides(from: rawValue)
    let countAfterSecondParse = TaskBoardLaneCollapsePreferences.decodeCount

    #expect(countAfterSecondParse == countAfterFirstParse)
  }

  @Test("A changed raw value invalidates the memo and re-decodes")
  func changedRawValueInvalidatesMemoAndReDecodes() {
    let firstRawValue = #"{"planning":true}"#
    let secondRawValue = #"{"planning":false}"#

    _ = TaskBoardLaneCollapsePreferences.overrides(from: firstRawValue)
    let countAfterFirstParse = TaskBoardLaneCollapsePreferences.decodeCount

    let secondResult = TaskBoardLaneCollapsePreferences.overrides(from: secondRawValue)
    let countAfterSecondParse = TaskBoardLaneCollapsePreferences.decodeCount

    #expect(countAfterSecondParse == countAfterFirstParse + 1)
    #expect(secondResult[.planning] == false)
  }

  @Test("toggledRawValue round-trips back to the original collapsed state")
  func toggledRawValueRoundTripsBackToOriginalState() {
    let originalIsCollapsed = TaskBoardLaneCollapsePreferences.isCollapsed(
      lane: .toReview,
      contentCount: 2,
      rawValue: TaskBoardLaneCollapsePreferences.emptyRawValue
    )

    let toggledOnceRawValue = TaskBoardLaneCollapsePreferences.toggledRawValue(
      lane: .toReview,
      contentCount: 2,
      rawValue: TaskBoardLaneCollapsePreferences.emptyRawValue
    )
    #expect(
      TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .toReview,
        contentCount: 2,
        rawValue: toggledOnceRawValue
      ) != originalIsCollapsed
    )

    let toggledTwiceRawValue = TaskBoardLaneCollapsePreferences.toggledRawValue(
      lane: .toReview,
      contentCount: 2,
      rawValue: toggledOnceRawValue
    )
    #expect(
      TaskBoardLaneCollapsePreferences.isCollapsed(
        lane: .toReview,
        contentCount: 2,
        rawValue: toggledTwiceRawValue
      ) == originalIsCollapsed
    )
  }
}
