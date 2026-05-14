import SwiftUI

enum PolicyCanvasPortColumnAlignment {
  case leading
  case trailing
}

struct PolicyCanvasPortColumn: View {
  let node: PolicyCanvasNode
  let ports: [PolicyCanvasPort]
  let alignment: PolicyCanvasPortColumnAlignment
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ZStack(alignment: stackAlignment) {
      ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
        PolicyCanvasPortView(
          node: node,
          port: port,
          viewModel: viewModel
        )
        .offset(
          y: PolicyCanvasLayout.portY(index: index, count: ports.count)
            - PolicyCanvasLayout.portDiameter / 2
        )
      }
    }
    .frame(
      width: PolicyCanvasLayout.nodeSize.width,
      height: PolicyCanvasLayout.nodeSize.height,
      alignment: stackAlignment
    )
    .offset(
      x: alignment == .leading
        ? -PolicyCanvasLayout.portDiameter / 2
        : PolicyCanvasLayout.portDiameter / 2,
      y: 0
    )
  }

  private var stackAlignment: Alignment {
    alignment == .leading ? .topLeading : .topTrailing
  }
}

private struct PolicyCanvasPortView: View {
  let node: PolicyCanvasNode
  let port: PolicyCanvasPort
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    if port.kind == .output {
      // Gesture protocol between `.draggable()` and `.simultaneousGesture(...)`
      // on the same view:
      //
      //  * `.draggable()` owns the actual drag session — it starts an
      //    NSDraggingSession when the OS recognizes the touch-down -> move
      //    gesture, carries the port payload, fires the drop destination on
      //    a matching `.dropDestination` (which calls
      //    `connectDroppedPortPayloads(...)` to commit the edge), and is
      //    cancelled by the OS on Esc, Cmd-Tab, or focus loss.
      //
      //  * The `.simultaneousGesture(DragGesture)` below does NOT participate
      //    in drop-target routing and never wins ownership of the touch — it
      //    only mirrors the cursor position so the rubber-band layer can
      //    paint a Bézier from the source anchor to the live cursor while
      //    the dragging session is mid-flight. It never writes to
      //    `nodes`/`edges`/`groups`/selection.
      //
      //  * Both gestures fire simultaneously because `.simultaneousGesture`
      //    bypasses the gesture exclusivity arbiter. The `.draggable()` side
      //    drives state mutation; the rubber-band side drives ephemeral
      //    preview state only. On `.onEnded` of the rubber-band the curve is
      //    cleared unconditionally — successful drops also clear it (via
      //    `connectDroppedPortPayloads` -> `clearPendingEdge()`), but the
      //    OS-cancel path (Esc/Cmd-Tab) only fires `.onEnded` reliably
      //    when the touch-down occurred inside the gesture's reference frame,
      //    so the scenePhase guard in `PolicyCanvasView` is the belt-and-
      //    braces fallback for OS-level interruption.
      portMarker
        .draggable(viewModel.portDragPayload(nodeID: node.id, portID: port.id))
        .simultaneousGesture(rubberBandGesture)
    } else {
      portMarker
        .dropDestination(for: String.self) { payloads, _ in
          viewModel.connectDroppedPortPayloads(
            payloads,
            targetNodeID: node.id,
            targetPortID: port.id
          )
        } isTargeted: { targeted in
          viewModel.setInputTargeted(
            targeted,
            nodeID: node.id,
            portID: port.id
          )
        }
    }
  }

  /// Fires alongside `.draggable()` to capture the live cursor position in
  /// the named canvas coordinate space. `.draggable()` owns the NSDraggingSession
  /// (so the drop destination still fires); this gesture only writes to the
  /// rubber-band preview state and never claims the drag itself. See the
  /// gesture-protocol comment in `body` for the full contract.
  private var rubberBandGesture: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named(PolicyCanvasCoordinateSpaces.canvas))
      .onChanged { value in
        if viewModel.pendingEdgePreview == nil {
          viewModel.beginPendingEdge(sourceNodeID: node.id, sourcePortID: port.id)
        }
        viewModel.updatePendingEdgeCursor(
          viewModel.canvasPoint(for: value.location)
        )
      }
      .onEnded { _ in
        // Drop on a valid input fires `connectDroppedPortPayloads` (which
        // already clears the preview). For drops on empty canvas or off-view,
        // this is the only clear path — keep it unconditional.
        viewModel.clearPendingEdge()
      }
  }

  private var portMarker: some View {
    let endpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: port.id,
      kind: port.kind
    )
    return Circle()
      .fill(port.kind == .output ? node.kind.accentColor : Color.white.opacity(0.92))
      .overlay {
        Circle()
          .stroke(
            viewModel.highlightedInput == endpoint ? Color.yellow : Color.black.opacity(0.5),
            lineWidth: viewModel.highlightedInput == endpoint ? 2 : 1
          )
      }
      .frame(
        width: PolicyCanvasLayout.portDiameter,
        height: PolicyCanvasLayout.portDiameter
      )
      .contentShape(Circle().inset(by: -PolicyCanvasLayout.portHitTestExtension))
      .help(port.title)
      .accessibilityLabel("\(node.title) \(port.title)")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasPort(
          node.id,
          port.id
        )
      )
  }
}
