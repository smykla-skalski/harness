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
  public static let openAnythingShowPinnedToggle =
    "harness.settings.open-anything.show-pinned"
  public static let openAnythingShowRecentToggle =
    "harness.settings.open-anything.show-recent"
  public static let openAnythingCmdClickBackgroundToggle =
    "harness.settings.open-anything.cmd-click-background"
  public static let openAnythingRestoreLastQueryToggle =
    "harness.settings.open-anything.restore-last-query"
  public static let openAnythingPrioritizeContextToggle =
    "harness.settings.open-anything.prioritize-context"

  public static func openAnythingRow(_ id: String) -> String {
    "harness.open-anything.row.\(slug(id))"
  }
}
