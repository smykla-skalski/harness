import Foundation

/// Not `@Observable` on purpose: writes here must not invalidate the view.
/// Only `hoveredCardID` (equality-guarded `@State` on the column) does that.
@MainActor
final class TaskBoardLaneHoverTracking {
  var location: CGPoint?
  var frames: [TaskBoardLaneCardFrame] = []
}
