import SwiftUI
import XCTest

@testable import HarnessMonitorUIPreviewable

@MainActor
final class SettingsDurationPickerRowTests: XCTestCase {
  func testCurrentSelectionUsesCustomTagForNonPresetInitialValue() {
    var seconds: UInt64 = 3_000
    let row = SettingsDurationPickerRow(
      title: "Refresh",
      presets: [30, 60, 120, 300, 600, 900, 1_800, 3_600],
      minSeconds: 30,
      seconds: Binding(get: { seconds }, set: { seconds = $0 }),
      pickerAccessibilityIdentifier: "picker"
    )

    XCTAssertEqual(row.currentSelection, .custom)
  }

  func testCurrentSelectionKeepsPresetTagForPresetInitialValue() {
    var seconds: UInt64 = 300
    let row = SettingsDurationPickerRow(
      title: "Refresh",
      presets: [30, 60, 120, 300, 600, 900, 1_800, 3_600],
      minSeconds: 30,
      seconds: Binding(get: { seconds }, set: { seconds = $0 }),
      pickerAccessibilityIdentifier: "picker"
    )

    XCTAssertEqual(row.currentSelection, .preset(300))
  }

  func testDecompositionPicksHoursForWholeHour() {
    let decomposition = SettingsDurationDecomposition(seconds: 7_200)
    XCTAssertEqual(decomposition.unit, .hours)
    XCTAssertEqual(decomposition.amount, 2)
    XCTAssertEqual(decomposition.seconds, 7_200)
  }

  func testDecompositionPicksMinutesForWholeMinuteUnderHour() {
    let decomposition = SettingsDurationDecomposition(seconds: 300)
    XCTAssertEqual(decomposition.unit, .minutes)
    XCTAssertEqual(decomposition.amount, 5)
    XCTAssertEqual(decomposition.seconds, 300)
  }

  func testDecompositionFallsBackToSecondsForRemainder() {
    let decomposition = SettingsDurationDecomposition(seconds: 90)
    XCTAssertEqual(decomposition.unit, .seconds)
    XCTAssertEqual(decomposition.amount, 90)
    XCTAssertEqual(decomposition.seconds, 90)
  }

  func testDecompositionHandlesSubMinuteValues() {
    let decomposition = SettingsDurationDecomposition(seconds: 30)
    XCTAssertEqual(decomposition.unit, .seconds)
    XCTAssertEqual(decomposition.amount, 30)
  }

  func testDecompositionRoundtripsForCommonPresets() {
    for seconds in [30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 21_600] {
      let decomposition = SettingsDurationDecomposition(seconds: UInt64(seconds))
      XCTAssertEqual(
        decomposition.seconds, UInt64(seconds),
        "decomposition should roundtrip \(seconds)s"
      )
    }
  }

  func testPresetLabelFormatsHours() {
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 3_600), "Every 1 hour")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 7_200), "Every 2 hours")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 21_600), "Every 6 hours")
  }

  func testPresetLabelFormatsMinutes() {
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 60), "Every 1 minute")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 300), "Every 5 minutes")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 1_800), "Every 30 minutes")
  }

  func testPresetLabelFormatsSeconds() {
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 30), "Every 30 seconds")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 1), "Every 1 second")
    XCTAssertEqual(SettingsDurationFormatter.presetLabel(seconds: 45), "Every 45 seconds")
  }

  func testUnitSecondsPerUnit() {
    XCTAssertEqual(SettingsDurationUnit.seconds.secondsPerUnit, 1)
    XCTAssertEqual(SettingsDurationUnit.minutes.secondsPerUnit, 60)
    XCTAssertEqual(SettingsDurationUnit.hours.secondsPerUnit, 3_600)
  }
}
