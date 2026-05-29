import Foundation

/// AppStorage-backed autosave debounce window for the policy canvas, surfaced
/// in Settings > Policies > Canvas. Stored as whole seconds; `0` means Off — no
/// debounced autosave runs, only Cmd+S and the scene-background flush save.
/// Mirrors `PolicyCanvasMinimapDefaults` (key + default) and adds the preset
/// set + the seconds -> milliseconds bridge the view model consumes.
enum PolicyCanvasAutosaveDefaults {
  /// AppStorage key for the debounce window, in seconds.
  static let debounceSecondsKey = "policyCanvas.autosaveDebounceSeconds"

  /// Off sentinel — no debounced autosave runs.
  static let offSeconds = 0

  /// Fresh-install default: 10s, matching
  /// `PolicyCanvasViewModel.defaultAutosaveDebounceMilliseconds`.
  static let defaultDebounceSeconds = 10

  /// Picker presets in seconds. `0` is Off; the rest coalesce a burst of edits
  /// over progressively longer windows.
  static let presetSeconds = [offSeconds, 5, 10, 30, 60]

  /// Human label for a preset row.
  static func label(forSeconds seconds: Int) -> String {
    seconds == offSeconds ? "Off" : "\(seconds)s"
  }

  /// Bridge a stored seconds value to the view model's millisecond debounce
  /// window. Off (and any stray negative) maps to `0`; the host reads that as
  /// "leave the autosave trigger unbound".
  static func milliseconds(forSeconds seconds: Int) -> UInt64 {
    UInt64(max(0, seconds)) * 1_000
  }
}
