import Foundation

/// The single source of truth the policy-canvas footer save-status text reads.
/// Distinct from `lastAutosaveOutcome` (which drives the failure-ceiling
/// decompensation logic): `saveActivity` is purely the user-facing progress cue
/// — a spinner while a debounced or manual save is queued or flushing, a brief
/// error marker on reject, and nothing at rest.
///
/// - `idle`: no save in flight and nothing queued; the status text is hidden.
/// - `pending`: the debounce window is armed (an edit landed, the save will
///   fire after the configured interval). The spinner shows so the user knows
///   the edit will be persisted.
/// - `saving`: a daemon round-trip is in flight (the debounce fired, or Cmd+S /
///   the Save button kicked a foreground save).
/// - `saved(at:)`: the last save landed clean. Hidden in the footer; the save
///   path adopts the new revision in place and stays visually quiet on success.
/// - `failed`: the last save was rejected. The detailed recovery flow stays on
///   the existing toast + sticky affordance; this is only a brief marker.
enum PolicyCanvasSaveActivity: Equatable {
  case idle
  case pending
  case saving
  case saved(at: Date)
  case failed
}

/// Pure view-state derived from a `PolicyCanvasSaveActivity`. Keeping the
/// mapping off the view keeps the footer status dumb and lets the contract be
/// unit tested without mounting SwiftUI.
struct PolicyCanvasSaveStatusPresentation: Equatable {
  enum Role: Equatable {
    case progress
    case success
    case failure
  }

  let isVisible: Bool
  let showsSpinner: Bool
  let label: String
  let symbolName: String?
  let role: Role

  /// Spoken affordance for VoiceOver. Avoids reading the trailing ellipsis of
  /// the visible "Saving…" label as punctuation.
  let accessibilityLabel: String
}

extension PolicyCanvasSaveActivity {
  var presentation: PolicyCanvasSaveStatusPresentation {
    switch self {
    case .idle:
      return PolicyCanvasSaveStatusPresentation(
        isVisible: false,
        showsSpinner: false,
        label: "",
        symbolName: nil,
        role: .progress,
        accessibilityLabel: ""
      )
    case .pending, .saving:
      // The debounce window and the in-flight round-trip read identically to
      // the user — both mean "your change will be / is being persisted".
      return PolicyCanvasSaveStatusPresentation(
        isVisible: true,
        showsSpinner: true,
        label: "Saving…",
        symbolName: nil,
        role: .progress,
        accessibilityLabel: "Saving changes"
      )
    case .saved:
      return PolicyCanvasSaveStatusPresentation(
        isVisible: false,
        showsSpinner: false,
        label: "",
        symbolName: nil,
        role: .success,
        accessibilityLabel: ""
      )
    case .failed:
      return PolicyCanvasSaveStatusPresentation(
        isVisible: true,
        showsSpinner: false,
        label: "Save failed",
        symbolName: "exclamationmark.triangle.fill",
        role: .failure,
        accessibilityLabel: "Save failed"
      )
    }
  }
}
