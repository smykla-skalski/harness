extension HarnessMonitorAccessibility {
  public static let openAnythingPalette = "harness.open-anything.palette"
  public static let openAnythingField = "harness.open-anything.field"
  public static let openAnythingEmptyState = "harness.open-anything.empty"
  public static let openAnythingSelectedState = "harness.open-anything.selected"
  public static let openAnythingGlobalHotKeyToggle =
    "harness.settings.open-anything.global-hotkey.enabled"
  public static let openAnythingGlobalHotKeyRecordButton =
    "harness.settings.open-anything.global-hotkey.record"
  public static let openAnythingGlobalHotKeyResetButton =
    "harness.settings.open-anything.global-hotkey.reset"

  public static func openAnythingRow(_ id: String) -> String {
    "harness.open-anything.row.\(slug(id))"
  }
}
