import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

/// Carries the canvas save action up to the app's File menu so plain Cmd+S
/// flushes the debounce immediately whenever a policy canvas window is key.
/// Mirrors `PolicyCanvasLayoutFocusDispatcher`: the host binds `save` to the
/// view's `saveDraft()` (which owns the store round-trip and sets the
/// save-status pill), and `HarnessMonitorAppCommands` invokes `performSave()`.
@MainActor
public final class PolicyCanvasSaveFocusDispatcher {
  public var save: (() -> Void)?

  public init() {}

  public func performSave() {
    save?()
  }
}

/// Focused value payload for the canvas save command. `canSave` gates the menu
/// item's enabled state (false in the lab / without a live store).
public struct PolicyCanvasSaveFocus: Equatable {
  public let canSave: Bool
  public let dispatcher: PolicyCanvasSaveFocusDispatcher

  public init(canSave: Bool, dispatcher: PolicyCanvasSaveFocusDispatcher) {
    self.canSave = canSave
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.canSave == rhs.canSave && lhs.dispatcher === rhs.dispatcher
  }
}
