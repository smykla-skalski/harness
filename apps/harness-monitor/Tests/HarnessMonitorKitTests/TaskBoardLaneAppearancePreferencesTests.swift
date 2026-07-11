import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane appearance preferences")
struct TaskBoardLaneAppearancePreferencesTests {
  @Test("Defaults use lane chrome when there are no overrides")
  func defaultsUseLaneChromeWhenThereAreNoOverrides() {
    let appearance = TaskBoardLaneAppearance()

    #expect(appearance.colorToken(for: .agenticReview) == .success)
    #expect(
      appearance.symbolName(for: .agenticReview)
        == TaskBoardLaneAppearancePreferences.defaultSymbolName(for: .agenticReview)
    )
    #expect(!appearance.hidesSymbol(for: .agenticReview))
    #expect(!appearance.hasOverride(for: .agenticReview))
  }

  @Test("Overrides persist through UserDefaults")
  func overridesPersistThroughUserDefaults() throws {
    let suiteName = "TaskBoardLaneAppearancePreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    var rawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
    rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .purple,
      for: .agenticReview,
      rawValue: rawValue
    )
    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
      "sparkles",
      for: .agenticReview,
      rawValue: rawValue
    )

    TaskBoardLaneAppearancePreferences.save(
      TaskBoardLaneAppearancePreferences.overrides(from: rawValue),
      to: userDefaults
    )
    userDefaults.synchronize()

    let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
    let storedRawValue = try #require(
      restartedDefaults.string(forKey: TaskBoardLaneAppearancePreferences.storageKey)
    )
    let restoredAppearance = TaskBoardLaneAppearance(rawValue: storedRawValue)

    #expect(restoredAppearance.colorToken(for: .agenticReview) == .purple)
    #expect(restoredAppearance.symbolName(for: .agenticReview) == "sparkles")
    #expect(restoredAppearance.hasOverride(for: .agenticReview))
  }

  @Test("Hidden symbols persist through UserDefaults")
  func hiddenSymbolsPersistThroughUserDefaults() throws {
    let suiteName = "TaskBoardLaneAppearancePreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
      false,
      for: .planning,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
    TaskBoardLaneAppearancePreferences.save(
      TaskBoardLaneAppearancePreferences.overrides(from: rawValue),
      to: userDefaults
    )
    userDefaults.synchronize()

    let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
    let storedRawValue = try #require(
      restartedDefaults.string(forKey: TaskBoardLaneAppearancePreferences.storageKey)
    )
    let restoredAppearance = TaskBoardLaneAppearance(rawValue: storedRawValue)

    #expect(restoredAppearance.symbolName(for: .planning) == nil)
    #expect(restoredAppearance.hidesSymbol(for: .planning))
    #expect(restoredAppearance.hasOverride(for: .planning))
  }

  @Test("Reset and default values remove overrides")
  func resetAndDefaultValuesRemoveOverrides() {
    var rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .purple,
      for: .testing,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
      "testtube.2",
      for: .testing,
      rawValue: rawValue
    )

    #expect(TaskBoardLaneAppearancePreferences.hasOverride(for: .testing, rawValue: rawValue))

    rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      TaskBoardLaneAppearancePreferences.defaultColorToken(for: .testing),
      for: .testing,
      rawValue: rawValue
    )
    #expect(TaskBoardLaneAppearancePreferences.hasOverride(for: .testing, rawValue: rawValue))

    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
      TaskBoardLaneAppearancePreferences.defaultSymbolName(for: .testing),
      for: .testing,
      rawValue: rawValue
    )
    #expect(rawValue == TaskBoardLaneAppearancePreferences.emptyRawValue)

    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
      false,
      for: .testing,
      rawValue: rawValue
    )
    #expect(TaskBoardLaneAppearance(rawValue: rawValue).symbolName(for: .testing) == nil)

    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
      true,
      for: .testing,
      rawValue: rawValue
    )
    #expect(rawValue == TaskBoardLaneAppearancePreferences.emptyRawValue)

    rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .pink,
      for: .testing,
      rawValue: rawValue
    )
    rawValue = TaskBoardLaneAppearancePreferences.resetRawValue(
      for: .testing,
      rawValue: rawValue
    )
    #expect(rawValue == TaskBoardLaneAppearancePreferences.emptyRawValue)
  }
}
