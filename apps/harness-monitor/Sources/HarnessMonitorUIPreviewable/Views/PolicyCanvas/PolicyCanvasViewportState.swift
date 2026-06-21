import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasViewportSelectionFocusRequest: Equatable {
  let id: UInt64
  let selection: PolicyCanvasSelection
}

/// Coarse trigger for the deferred viewport-centering `.task(id:)`. It flips
/// only on transitions that should actually re-center - a new graph (route
/// key), routes landing for the current graph (applied key), or an explicit
/// recenter request - never on per-recompute geometry. Folding the routed
/// signature or the projection-match flag in here re-armed the task on every
/// route recompute (each drag tick included), which both fought a live drag by
/// re-centering mid-gesture and tripped SwiftUI's "tried to update multiple
/// times per frame" fault.
struct PolicyCanvasViewportCenteringRouteState: Equatable {
  let currentRouteKey: PolicyCanvasRouteWorkerKey
  let appliedRouteKey: PolicyCanvasRouteWorkerKey?
  let viewportCenteringGeneration: UInt64
}
