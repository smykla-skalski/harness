import SwiftUI

extension PolicyCanvasViewModel {
  // MARK: - Empty state

  /// True when no nodes or groups exist. Drives the empty-state placeholder
  /// in the workspace overlay. Edges follow nodes, so they are not consulted
  /// separately — an edge without endpoints is unreachable from the public
  /// mutators.
  var isEmpty: Bool {
    nodes.isEmpty && groups.isEmpty
  }

  // MARK: - Rubber-band edge preview

  /// Begin a rubber-band edge preview from `sourceNodeID/sourcePortID`. Only
  /// output ports start a drag; the call is a no-op when the port is not
  /// resolvable or is not an output. The initial cursor sits at the source
  /// anchor so the curve is collapsed until the gesture provides a real
  /// translation.
  func beginPendingEdge(sourceNodeID: String, sourcePortID: String) {
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: sourceNodeID,
      portID: sourcePortID,
      kind: .output
    )
    guard
      let node = node(sourceNodeID),
      node.outputPorts.contains(where: { $0.id == sourcePortID }),
      let anchor = portAnchor(for: endpoint)
    else {
      return
    }
    setPendingEdge(
      PolicyCanvasPendingEdgePreview(
        source: endpoint,
        sourceAnchor: anchor,
        cursor: anchor
      )
    )
  }

  /// Track the live cursor position (in canvas coords) for an in-flight
  /// rubber-band drag. No-op when no preview is active.
  func updatePendingEdgeCursor(_ cursor: CGPoint) {
    guard var current = pendingEdgePreview else {
      return
    }
    current.cursor = cursor
    // `hasPendingEdge` is already true; the writer keeps both in sync but the
    // bit doesn't flip on a cursor-only update — only views that subscribe
    // to `pendingEdgePreview` (the rubber-band layer) re-evaluate.
    setPendingEdge(current)
  }

  /// Drop the rubber-band preview. Called on a successful or rejected drop,
  /// and on gesture cancel. Idempotent.
  ///
  // CHERRY-PICK NOTE: When merging on top of Wave 2D, extend
  // clearTransientGestureState() in PolicyCanvasViewModel+Commands.swift to
  // also call clearPendingEdge() so Escape during a rubber-band drag clears
  // the curve. Wave 2D's helper currently only knows about
  // highlightedInput/highlightedGroupID; the pendingEdgePreview field is
  // added in Wave 2F and the unified helper below (clearTransientGestureState)
  // is the post-merge name to consolidate on.
  func clearPendingEdge() {
    setPendingEdge(nil)
    highlightedInput = nil
  }

  /// Drop every piece of in-flight gesture state in one call: the rubber-band
  /// edge preview, the highlighted input port stroke, and the highlighted
  /// drop-target group. Use this from interruption surfaces (scenePhase
  /// transitions, Escape keypress, document republish) where the canvas needs
  /// to return to a resting state regardless of which gesture was mid-flight.
  ///
  /// Idempotent — every write is to optional storage that may already be nil.
  func clearTransientGestureState() {
    setPendingEdge(nil)
    highlightedInput = nil
    highlightedGroupID = nil
  }

  /// Single writer that keeps `pendingEdgePreview` and the observed
  /// `hasPendingEdge` presence-bit in sync. Internal callers must always go
  /// through this — direct writes to `pendingEdgePreview` would leave the
  /// presence bit stale, and any non-rubber-band view that subscribes to
  /// `hasPendingEdge` would miss the transition.
  private func setPendingEdge(_ value: PolicyCanvasPendingEdgePreview?) {
    pendingEdgePreview = value
    let nextHas = value != nil
    if hasPendingEdge != nextHas {
      hasPendingEdge = nextHas
    }
  }
}
