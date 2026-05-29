import SwiftUI

/// Dispatcher bridge that the canvas viewport publishes through
/// `focusedSceneValue` so a scene-level `CommandGroup` can route the menu /
/// keyboard chord into the live viewport. Same shape as
/// `HarnessSidebarSearchFocusDispatcher`: a reference object that lets
/// `Equatable` rely on identity instead of closure equality (closures are
/// not equatable, and value-typed structs that hold closures cannot satisfy
/// the `@FocusedValue(...) Equatable` contract).
@MainActor
public final class PolicyCanvasZoomFocusDispatcher {
  public var zoomIn: (() -> Void)?
  public var zoomOut: (() -> Void)?
  public var resetZoom: (() -> Void)?

  public init() {}

  public func performZoomIn() {
    zoomIn?()
  }

  public func performZoomOut() {
    zoomOut?()
  }

  public func performResetZoom() {
    resetZoom?()
  }
}

/// Zoom command payload embedded in `PolicyCanvasCommandFocus`. The scene-level
/// `CommandGroup` derives View-menu items and their keyboard chords (Cmd-+,
/// Cmd-=, Cmd--, Cmd-0) from the combined Policy Canvas command focus.
///
/// Equality is identity-based on `dispatcher` so a republish from a single
/// canvas window does not trigger a FocusedValues update on every render.
public struct PolicyCanvasZoomFocus: Equatable {
  public let dispatcher: PolicyCanvasZoomFocusDispatcher

  public init(dispatcher: PolicyCanvasZoomFocusDispatcher) {
    self.dispatcher = dispatcher
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.dispatcher === rhs.dispatcher
  }
}
