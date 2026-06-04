import Foundation

extension PolicyCanvasViewModel {
  /// Maximum consecutive autosave rejects before the subsystem flips to
  /// `.disabled(reason:)`. Three is enough to ride out a brief daemon hiccup
  /// without burying the user under a stack of "Autosave rejected" toasts
  /// that each restore work they were still typing.
  static let autosaveFailureCeiling: Int = 3

  /// Acceptance-flash lifetime for the group drop affordance (Wave 4K P36).
  /// 600ms is the upper bound on a "this just happened" affordance, long
  /// enough for the user to register the visual confirmation, short enough
  /// to fade before the next gesture begins. The flash auto-clears after
  /// this interval via `triggerGroupAcceptanceFlash`.
  static let groupAcceptanceFlashDuration: Duration = .milliseconds(600)
}
