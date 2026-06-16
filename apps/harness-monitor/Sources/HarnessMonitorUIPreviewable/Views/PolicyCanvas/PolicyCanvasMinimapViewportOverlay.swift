import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
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
  private var observedStatesByIdentity: [String: PolicyCanvasViewportObservedState] = [:]
  private var nilIdentityObservedState: PolicyCanvasViewportObservedState?

  init(observedState: PolicyCanvasViewportObservedState? = nil) {
    nilIdentityObservedState = observedState
  }

  func observedState(for identity: String?) -> PolicyCanvasViewportObservedState? {
    guard let identity else {
      return nilIdentityObservedState
    }
    return observedStatesByIdentity[identity]
  }

  func update(
    _ observedState: PolicyCanvasViewportObservedState,
    for identity: String?
  ) {
    guard self.observedState(for: identity) != observedState else {
      return
    }
    if let identity {
      observedStatesByIdentity[identity] = observedState
    } else {
      nilIdentityObservedState = observedState
    }
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
  let viewportIdentity: String?
  let storedPipelineStateRaw: String
  let suppressesSceneStorage: Bool
  let contentBounds: CGRect
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  let onScrollRequest: (CGPoint) -> Void

  var body: some View {
    let viewportRect =
      observationStore.observedState(for: viewportIdentity)?.visibleContentRect
      ?? restoredViewportRect
      ?? contentBounds
    let nodeFramesByID = policyCanvasNodeFramesByID(nodes: viewModel.nodes, edges: viewModel.edges)
    let nodeFrames = viewModel.nodes.compactMap { nodeFramesByID[$0.id] }
    let snapshot = policyCanvasMinimapSnapshot(
      contentBounds: contentBounds,
      viewportRect: viewportRect,
      nodeFrames: nodeFrames,
      groupFrames: viewModel.groups.map(\.frame)
    )
    PolicyCanvasMinimapOverlay(
      snapshot: snapshot,
      minimapCenteringModeOverride: minimapCenteringModeOverride
    ) { targetOrigin in
      onScrollRequest(targetOrigin)
    }
  }

  private var restoredViewportRect: CGRect? {
    PolicyCanvasView.sceneState(
      for: viewportIdentity,
      raw: storedPipelineStateRaw,
      suppressesSceneStorage: suppressesSceneStorage
    )?
    .viewportRect
  }
}
