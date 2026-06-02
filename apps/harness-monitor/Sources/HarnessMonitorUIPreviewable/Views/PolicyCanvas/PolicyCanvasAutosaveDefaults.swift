import Foundation

/// AppStorage-backed autosave debounce window for the policy canvas, surfaced
/// in Settings > Policies > Canvas. Stored as whole seconds; `0` means Off — no
/// debounced autosave runs, only Cmd+S and the scene-background flush save.
/// Mirrors `PolicyCanvasMinimapDefaults` (key + default) and adds the preset
/// set + the seconds -> milliseconds bridge the view model consumes.
public enum PolicyCanvasAutosaveDefaults {
  /// AppStorage key for the debounce window, in seconds.
  public static let debounceSecondsKey = "policyCanvas.autosaveDebounceSeconds"

  /// Off sentinel — no debounced autosave runs.
  public static let offSeconds = 0

  /// Fresh-install burst ceiling: 2s, matching
  /// `PolicyCanvasViewModel.defaultAutosaveDebounceMilliseconds`.
  public static let defaultDebounceSeconds = 2

  /// Picker presets in seconds. `0` is Off; the rest coalesce a burst of edits
  /// over progressively longer windows.
  public static let presetSeconds = [offSeconds, 2, 5, 10, 30]

  /// Human label for a preset row.
  public static func label(forSeconds seconds: Int) -> String {
    seconds == offSeconds ? "Off" : "\(seconds)s"
  }

  /// Bridge a stored seconds value to the view model's millisecond debounce
  /// window. Off (and any stray negative) maps to `0`; the host reads that as
  /// "leave the autosave trigger unbound".
  public static func milliseconds(forSeconds seconds: Int) -> UInt64 {
    UInt64(max(0, seconds)) * 1_000
  }
}
