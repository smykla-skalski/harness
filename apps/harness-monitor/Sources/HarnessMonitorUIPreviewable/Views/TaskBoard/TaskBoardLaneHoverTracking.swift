import CoreGraphics
import Foundation

/// Not `@Observable` on purpose: writes here must not invalidate the view.
/// Only `hoveredCardID` (equality-guarded `@State` on the column) does that.
///
/// Each card reports its own frame through `.onGeometryChange`, so this keeps a
/// per-card map rather than one aggregated array. The array used to flow through
/// a single `PreferenceKey` reduced across every card in a `LazyVStack`; that
/// aggregate genuinely changed several times as lazy children measured in over
/// one layout pass, and SwiftUI faulted it as "bound preference ... tried to
/// update multiple times per frame". Per-card geometry has no cross-sibling
/// reduce, so there is nothing to over-update.
@MainActor
final class TaskBoardLaneHoverTracking {
  var location: CGPoint?
  private var frames: [TaskBoardLaneCardHoverID: CGRect] = [:]

  func setFrame(_ frame: CGRect, for id: TaskBoardLaneCardHoverID) {
    frames[id] = frame
  }

  func removeFrame(for id: TaskBoardLaneCardHoverID) {
    frames.removeValue(forKey: id)
  }

  /// Cards never overlap in a lane, so at most one rect contains any point.
  func cardID(at point: CGPoint) -> TaskBoardLaneCardHoverID? {
    frames.first { $0.value.contains(point) }?.key
  }
}
