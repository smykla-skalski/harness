import Foundation
import SwiftUI
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

  @Test("Custom colors persist through UserDefaults")
  func customColorsPersistThroughUserDefaults() throws {
    let suiteName = "TaskBoardLaneAppearancePreferencesTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let rawValue = TaskBoardLaneAppearancePreferences.settingCustomColor(
      Color(.sRGB, red: 0.24, green: 0.48, blue: 0.72, opacity: 1),
      for: .testing,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
    TaskBoardLaneAppearancePreferences.save(
      TaskBoardLaneAppearancePreferences.overrides(from: rawValue),
      to: userDefaults
    )
    userDefaults.synchronize()

    let restartedDefaults = try #require(UserDefaults(suiteName: suiteName))
    let restored = TaskBoardLaneAppearancePreferences.load(from: restartedDefaults)
    let customColor = try #require(restored[.testing]?.customColor)

    #expect(customColor == TaskBoardLaneCustomColor(red: 0.24, green: 0.48, blue: 0.72))
    #expect(TaskBoardLaneAppearance(rawValue: rawValue).hasColorOverride(for: .testing))
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

  @Test("Color reset keeps symbol overrides")
  func colorResetKeepsSymbolOverrides() {
    var rawValue = TaskBoardLaneAppearancePreferences.settingCustomColor(
      Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 1),
      for: .inReview,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
    rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
      "eye",
      for: .inReview,
      rawValue: rawValue
    )

    rawValue = TaskBoardLaneAppearancePreferences.resetColorRawValue(
      for: .inReview,
      rawValue: rawValue
    )
    let appearance = TaskBoardLaneAppearance(rawValue: rawValue)

    #expect(!appearance.hasColorOverride(for: .inReview))
    #expect(appearance.symbolName(for: .inReview) == "eye")
    #expect(appearance.hasSymbolOverride(for: .inReview))
  }

  @Test("Settings lane appearance uses visual popover controls")
  func settingsLaneAppearanceUsesVisualPopoverControls() throws {
    let source = try sourceFile(
      named: "Views/Settings/SettingsTaskBoardLaneAppearanceSection.swift"
    )

    #expect(source.contains(".popover("))
    #expect(source.contains("ColorPicker("))
    #expect(source.contains("Customize"))
    #expect(source.contains("Clear Symbol"))
    #expect(source.contains("Reset Color"))
    #expect(source.contains("Reset Symbol"))
    #expect(source.contains("Label(\"Reset\", systemImage: \"arrow.counterclockwise\")"))
    #expect(source.contains("HarnessMonitorTextSize.scaledFont(.body.weight(.medium)"))
    #expect(!source.contains("TextField("))
    #expect(!source.contains("Show Symbol"))
    #expect(!source.contains("Remove Symbol"))
    #expect(!source.contains("Reset Lane"))
    #expect(!source.contains("Top Bar Color"))

    let colorRange = try #require(source.range(of: "colorSection"))
    let symbolRange = try #require(source.range(of: "symbolSection"))
    #expect(colorRange.lowerBound < symbolRange.lowerBound)
  }

  private func sourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor")
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
