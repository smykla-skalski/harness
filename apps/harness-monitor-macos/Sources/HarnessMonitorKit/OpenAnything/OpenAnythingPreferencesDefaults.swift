import Foundation

/// Storage keys and defaults for the Open Anything palette preferences. Kit-side
/// so the palette view (Unit 8) can read them without importing the settings UI
/// module. The hot-key descriptor and enabled flag are owned by
/// `OpenAnythingHotKeyDefaults`; this enum carries the four toggle preferences
/// that live alongside the hot-key controls in `SettingsOpenAnythingSection`.
public enum OpenAnythingPreferencesDefaults {
  public static let showPinnedKey = "harness.openAnything.showPinned"
  public static let showRecentKey = "harness.openAnything.showRecent"
  public static let cmdClickBackgroundKey = "harness.openAnything.cmdClickBackground"
  public static let restoreLastQueryKey = "harness.openAnything.restoreLastQuery"

  public static let showPinnedDefault = true
  public static let showRecentDefault = true
  public static let cmdClickBackgroundDefault = true
  public static let restoreLastQueryDefault = false
}
