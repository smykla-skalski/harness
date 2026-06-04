import Foundation

/// Named coordinate spaces used by gesture-coordinate translations within the
/// policy canvas. The workspace declares each space on the appropriate view
/// so DragGesture(coordinateSpace:) reads positions relative to the right
/// container regardless of the surrounding chrome layout.
public enum PolicyCanvasCoordinateSpaces {
  /// Canvas document space inside the native scroll host. Position values are
  /// already expressed in canvas units, even while AppKit magnification is
  /// active.
  public static let canvas = "policy-canvas.workspace"
}

/// Outcome of the most recent autosave round-trip. Surfaced to the chrome so
/// the user knows the autosave subsystem is alive (`succeeded`), still
/// flushing (`pending`), or has hit a reject the manual Save button must
/// resolve (`failed`). `idle` is the cold-start state before any autosave
/// has fired, and stays in place after a manual save reload (autosave isn't
/// the most recent attempt anymore).
///
/// `.disabled(reason:)` is the decompensation state: after the consecutive
/// failure ceiling fires (see `PolicyCanvasViewModel.autosaveFailureCeiling`),
/// the autosave scheduler refuses to fire and the chrome shows a sticky
/// affordance telling the user to save manually. A successful manual save
/// clears the failure counter and flips back to `succeeded(at:)`.
public enum PolicyCanvasAutosaveOutcome: Equatable {
  case idle
  case pending
  case succeeded(at: Date)
  case failed(at: Date)
  case disabled(reason: String)
}
