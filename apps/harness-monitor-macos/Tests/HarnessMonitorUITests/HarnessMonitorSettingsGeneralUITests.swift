import XCTest

@MainActor
final class HarnessMonitorSettingsGeneralUITests: HarnessMonitorUITestCase {
  func testSettingsTimeZonePickerSupportsCustomZoneContract() throws {
    assertGeneralSettingsContract(
      expectedMode: "auto",
      timeZoneModeOverride: "custom",
      customTimeZoneOverride: "Europe/Warsaw",
      expectedTimeZoneMode: "custom",
      expectedTimeZone: "Europe/Warsaw"
    )
  }
}
