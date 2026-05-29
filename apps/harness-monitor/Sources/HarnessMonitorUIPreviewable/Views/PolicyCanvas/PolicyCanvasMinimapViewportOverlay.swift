import HarnessMonitorKit
import SwiftUI

/// Holds the live viewport rect (scroll position + zoom) the native canvas
/// scroll view reports. Kept as a standalone `@Observable` so a scroll updates
/// only the views that read it - the minimap viewport indicator - instead of
/// re-evaluating the whole `PolicyCanvasViewport` body. Reading the rect in the
/// parent body would rebuild the hosted snapshot and re-render the entire
/// canvas content tree (grid, every node, every edge, every label) once per
/// scroll frame, which is the choppiness this split removes.
@Observable
@MainActor
final class PolicyCanvasViewportObservationStore {
  var observedState: PolicyCanvasViewportObservedState?

  init(observedState: PolicyCanvasViewportObservedState? = nil) {
    self.observedState = observedState
  }
}

/// Minimap overlay that owns the per-scroll viewport read. Isolating the
/// `observationStore.observedState` access in this small subview keeps the
/// scroll hot path off the parent viewport body: only the minimap re-evaluates
/// as the user pans. Node and group frames still come from the view model so
/// the minimap stays correct when the graph itself changes.
struct PolicyCanvasMinimapViewportOverlay: View {
  let viewModel: PolicyCanvasViewModel
  let observationStore: PolicyCanvasViewportObservationStore
  let contentBounds: CGRect
  let onScrollRequest: (CGPoint) -> Void

  var body: some View {
    let nodeFrames = viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    }
    let snapshot = policyCanvasMinimapSnapshot(
      contentBounds: contentBounds,
      viewportRect: observationStore.observedState?.visibleContentRect ?? contentBounds,
      nodeFrames: nodeFrames,
      groupFrames: viewModel.groups.map(\.frame)
    )
    PolicyCanvasMinimapOverlay(snapshot: snapshot) { targetOrigin in
      onScrollRequest(targetOrigin)
    }
  }
}
