import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board lane appearance preferences")
@MainActor
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

  @Test("Legacy Umbrella override loads as Backlog and writes canonically")
  func legacyUmbrellaOverrideLoadsAsBacklogAndWritesCanonically() {
    let legacyRawValue = #"{"umbrella":{"colorToken":"purple","symbolName":"archivebox"}}"#

    let overrides = TaskBoardLaneAppearancePreferences.overrides(from: legacyRawValue)
    let canonicalRawValue = TaskBoardLaneAppearancePreferences.rawValue(for: overrides)

    #expect(overrides[.backlog]?.colorToken == .purple)
    #expect(overrides[.backlog]?.symbolName == "archivebox")
    #expect(canonicalRawValue.contains(#""backlog""#))
    #expect(!canonicalRawValue.contains("umbrella"))
  }

  @Test("Repeated parses of the same raw value return equal results")
  func repeatedParsesOfSameRawValueReturnEqualResults() {
    let rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .teal,
      for: .inProgress,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )

    let first = TaskBoardLaneAppearancePreferences.overrides(from: rawValue)
    let second = TaskBoardLaneAppearancePreferences.overrides(from: rawValue)

    #expect(first == second)
  }

  @Test("Repeated raw value does not re-invoke the decoder")
  func repeatedRawValueDoesNotReinvokeDecoder() {
    let rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .mint,
      for: .todo,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )

    _ = TaskBoardLaneAppearancePreferences.overrides(from: rawValue)
    let countAfterFirstParse = TaskBoardLaneAppearancePreferences.decodeCount

    _ = TaskBoardLaneAppearancePreferences.overrides(from: rawValue)
    let countAfterSecondParse = TaskBoardLaneAppearancePreferences.decodeCount

    #expect(countAfterSecondParse == countAfterFirstParse)
  }

  @Test("A changed raw value invalidates the memo and re-decodes")
  func changedRawValueInvalidatesMemoAndReDecodes() {
    let firstRawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .blue,
      for: .failed,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
    let secondRawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
      .pink,
      for: .failed,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )

    _ = TaskBoardLaneAppearancePreferences.overrides(from: firstRawValue)
    let countAfterFirstParse = TaskBoardLaneAppearancePreferences.decodeCount

    let secondResult = TaskBoardLaneAppearancePreferences.overrides(from: secondRawValue)
    let countAfterSecondParse = TaskBoardLaneAppearancePreferences.decodeCount

    #expect(countAfterSecondParse == countAfterFirstParse + 1)
    #expect(secondResult[.failed]?.colorToken == .pink)
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
    #expect(
      source.contains("SettingsTaskBoardLaneColorPicker(lane: lane, rawValue: $rawValue)")
    )
    #expect(source.contains("Button(\"Customize\")"))
    #expect(source.contains("laneIndicator(for: lane)"))
    #expect(source.contains("let symbolName = appearance.symbolName(for: lane)"))
    #expect(source.contains("height: symbolName == nil ? 18 : 30"))
    #expect(source.contains("Label(\"Clear\", systemImage: \"slash.circle\")"))
    #expect(source.contains("Label(\"Reset\", systemImage: \"arrow.counterclockwise\")"))
    #expect(source.contains("HarnessMonitorTextSize.scaledFont(.body.weight(.medium)"))
    #expect(source.contains("\"terminal\""))
    #expect(source.contains("\"gearshape\""))
    #expect(source.contains("\"checkmark.circle\""))
    #expect(!source.contains("TextField("))
    #expect(!source.contains("Show Symbol"))
    #expect(!source.contains("Remove Symbol"))
    #expect(!source.contains("Clear Symbol"))
    #expect(!source.contains("Reset Color"))
    #expect(!source.contains("Reset Symbol"))
    #expect(!source.contains("Reset Lane"))
    #expect(!source.contains("Top Bar Color"))
    // The whole point of the popover picker: nothing here may reach for the
    // shared NSColorPanel, which SwiftUI's ColorPicker opens in its own window.
    #expect(!source.contains("ColorPicker("))
    #expect(!source.contains("NSColorWell"))
    #expect(!source.contains("NSViewRepresentable"))
    #expect(!source.contains("@objc"))
    #expect(!source.contains("import AppKit"))
    #expect(!source.contains("customizeButtonLabel"))
    #expect(!source.contains("?? \"slash.circle\""))
    #expect(!source.contains("cardsSection"))
    #expect(!source.contains("priorityBadgeBinding"))
    #expect(!source.contains("Toggle(\"Priority Badge\""))
    #expect(
      !source.contains("TaskBoardLaneAppearancePreferences.settingPriorityBadgeVisibility(")
    )

    let colorRange = try #require(source.range(of: "colorSection"))
    let symbolRange = try #require(source.range(of: "symbolSection"))
    #expect(colorRange.lowerBound < symbolRange.lowerBound)
  }

  @Test("Lane color picker keeps both paths inside the popover")
  func laneColorPickerKeepsBothPathsInsideThePopover() throws {
    let source = try sourceFile(named: "Views/Settings/SettingsTaskBoardLaneColorPicker.swift")

    // Presets must go through the token path rather than the custom-color one.
    // A token resolves through the theme and keeps tracking light and dark;
    // writing a preset as a frozen sRGB triple would pin the lane to whichever
    // appearance happened to be active when it was picked.
    #expect(source.contains("TaskBoardLaneColorToken.allCases"))
    #expect(source.contains("TaskBoardLaneAppearancePreferences.settingColorToken("))
    #expect(source.contains("Saturation("))
    #expect(source.contains("HueSlider("))
    #expect(!source.contains("ColorPicker("))
    // Matches the call, not the prose: the file comment explains why the panel
    // is being avoided and has every right to name it.
    #expect(!source.contains("NSColorPanel."))
    // A nested popover would be another window, which is what #532 removed.
    #expect(!source.contains(".popover("))
  }

  @Test("Lane color components round-trip a stored color")
  func laneColorComponentsRoundTripAStoredColor() throws {
    let original = Color(.sRGB, red: 0.24, green: 0.58, blue: 0.87, opacity: 1)
    let restored = TaskBoardLaneColorComponents(original).color
    let originalRGB = try #require(NSColor(original).usingColorSpace(.sRGB))
    let restoredRGB = try #require(NSColor(restored).usingColorSpace(.sRGB))

    #expect(abs(originalRGB.redComponent - restoredRGB.redComponent) < 0.01)
    #expect(abs(originalRGB.greenComponent - restoredRGB.greenComponent) < 0.01)
    #expect(abs(originalRGB.blueComponent - restoredRGB.blueComponent) < 0.01)
  }

  @Test("A desaturated lane color no longer reports the hue that produced it")
  func desaturatedLaneColorLosesItsHue() {
    // This is why the picker holds the drag components in `@State` instead of
    // re-deriving them from the lane on every change: drag down to grey and
    // the stored color cannot say which hue you came from, so the marker would
    // jump to red mid-gesture.
    let grey = Color(hue: 0.6, saturation: 0, brightness: 0.5)

    #expect(TaskBoardLaneColorComponents(grey).hue == 0)
  }

  @Test("Lane palette hues resolve to calibrated theme assets, not raw system colours")
  func lanePaletteHuesResolveToThemeAssets() throws {
    let rawByToken: [(TaskBoardLaneColorToken, Color)] = [
      (.blue, .blue), (.teal, .teal), (.purple, .purple), (.pink, .pink), (.mint, .mint),
    ]
    let dark = try #require(NSAppearance(named: .darkAqua))
    var deltas: [TaskBoardLaneColorToken: Double] = [:]
    dark.performAsCurrentDrawingAppearance {
      for (token, raw) in rawByToken {
        guard
          let resolved = NSColor(token.color).usingColorSpace(.sRGB),
          let system = NSColor(raw).usingColorSpace(.sRGB)
        else { continue }
        deltas[token] =
          abs(Double(resolved.redComponent - system.redComponent))
          + abs(Double(resolved.greenComponent - system.greenComponent))
          + abs(Double(resolved.blueComponent - system.blueComponent))
      }
    }
    for (token, _) in rawByToken {
      let delta = try #require(deltas[token])
      #expect(delta > 0.05, "\(token) still resolves to the raw system colour")
    }
  }

  @Test("Umbrella lane default clears the WCAG AA luminance floor on the dark canvas")
  func umbrellaLaneDefaultClearsContrastFloor() throws {
    #expect(TaskBoardLaneAppearancePreferences.defaultColorToken(for: .umbrella) == .purple)
    let dark = try #require(NSAppearance(named: .darkAqua))
    var luminance = 0.0
    dark.performAsCurrentDrawingAppearance {
      guard let purple = NSColor(TaskBoardLaneColorToken.purple.color).usingColorSpace(.sRGB)
      else { return }
      luminance = Self.relativeLuminance(purple)
    }
    // Against the ~#1E1E1E board canvas (luminance ~0.013) a foreground needs a
    // relative luminance of ~0.234 to reach 4.5:1. Raw system purple measures
    // ~0.20 and fails; the calibrated purple must clear the floor.
    #expect(luminance >= 0.234)
  }

  private static func relativeLuminance(_ color: NSColor) -> Double {
    func linear(_ component: CGFloat) -> Double {
      let value = Double(component)
      return value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.redComponent)
      + 0.7152 * linear(color.greenComponent)
      + 0.0722 * linear(color.blueComponent)
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
