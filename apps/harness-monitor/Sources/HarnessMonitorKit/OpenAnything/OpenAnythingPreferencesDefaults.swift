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
  public static let perDomainLimitKey = "harness.openAnything.perDomainLimit"
  public static let scopeToWindowKey = "harness.openAnything.scopeToWindow"
  public static let prioritizeContextKey = "harness.openAnything.prioritizeContext"
  /// Serialized `NSStringFromPoint` origin of the palette panel once the user
  /// drags it. Absent until the first move, which signals "center by default"
  public static let windowFrameOriginKey = "harness.openAnything.windowFrameOrigin"
  /// Whether the palette paints its translucent glass background. When false the
  /// floating glass modifier takes its opaque fallback path
  public static let transparencyEnabledKey = "harness.openAnything.transparencyEnabled"

  public static let showPinnedDefault = true
  public static let showRecentDefault = true
  public static let cmdClickBackgroundDefault = true
  public static let restoreLastQueryDefault = false
  public static let perDomainLimitDefault = 6
  public static let perDomainLimitMin = 3
  public static let perDomainLimitMax = 12
  public static let scopeToWindowDefault = false
  public static let prioritizeContextDefault = true
  public static let transparencyEnabledDefault = true
}
