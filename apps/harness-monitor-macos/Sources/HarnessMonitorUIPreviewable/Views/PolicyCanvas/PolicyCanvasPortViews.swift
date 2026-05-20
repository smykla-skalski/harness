import SwiftUI

enum PolicyCanvasPortColumnAlignment {
  case leading
  case trailing
  case top
  case bottom
}

struct PolicyCanvasPortColumn: View {
  let node: PolicyCanvasNode
  let ports: [PolicyCanvasPort]
  let alignment: PolicyCanvasPortColumnAlignment
  let viewModel: PolicyCanvasViewModel
  let visibleSides: PolicyCanvasPortVisibilityMap
  let markerLayout: PolicyCanvasPortMarkerLayout
  var isAuxiliary = false

  var body: some View {
    // One ForEach over a flat `[PortMarkerPlacement]` instead of nested
    // `ForEach(ports.indices) { ForEach(markers(for:)) }`. The previous nesting
    // doubled the per-transaction `External: UInt32 -> ForEach<…>.Evictor`
    // edge count (45k edges/30s in the settings-open trace) because every
    // SwiftUI frame stamps each ForEach state independently. Flattening drops
    // half of those edges and also hoists the per-port marker computation out
    // of the inner ForEach data argument so the array identity is stable
    // across consecutive ticks with the same inputs.
    ZStack(alignment: stackAlignment) {
      ForEach(placements) { placement in
        PolicyCanvasPortView(
          node: node,
          port: placement.port,
          side: portSide,
          viewModel: viewModel,
          isAuxiliary: isAuxiliary || !placement.marker.allowsInteraction,
          allowsInteraction: placement.marker.allowsInteraction
        )
        .offset(placement.offset)
      }
    }
    .frame(
      width: PolicyCanvasLayout.nodeSize.width,
      height: PolicyCanvasLayout.nodeSize.height,
      alignment: stackAlignment
    )
    .offset(
      x: frameOffset.width,
      y: frameOffset.height
    )
    .accessibilityHidden(isAuxiliary)
  }

  private var placements: [PolicyCanvasPortPlacement] {
    let count = ports.count
    let side = portSide
    var result: [PolicyCanvasPortPlacement] = []
    result.reserveCapacity(ports.count)
    for index in ports.indices {
      let port = ports[index]
      let endpoint = PolicyCanvasPortEndpoint(
        nodeID: node.id,
        portID: port.id,
        kind: port.kind
      )
      let isVisible = policyCanvasVisiblePortSides(
        for: endpoint,
        visibility: visibleSides
      )
      .contains(side)
      let markers = markerLayout.markers(for: endpoint, side: side, isVisible: isVisible)
      for marker in markers {
        result.append(
          PolicyCanvasPortPlacement(
            id: "\(port.id)#\(marker.id)",
            port: port,
            marker: marker,
            offset: offset(index: index, count: count, marker: marker)
          )
        )
      }
    }
    return result
  }

  private var stackAlignment: Alignment {
    switch alignment {
    case .leading:
      .topLeading
    case .trailing:
      .topTrailing
    case .top:
      .topLeading
    case .bottom:
      .bottomLeading
    }
  }

  private var portSide: PolicyCanvasPortSide {
    switch alignment {
    case .leading:
      .leading
    case .trailing:
      .trailing
    case .top:
      .top
    case .bottom:
      .bottom
    }
  }

  private var frameOffset: CGSize {
    switch alignment {
    case .leading:
      CGSize(width: -PolicyCanvasLayout.portDiameter / 2, height: 0)
    case .trailing:
      CGSize(width: PolicyCanvasLayout.portDiameter / 2, height: 0)
    case .top:
      CGSize(width: 0, height: -PolicyCanvasLayout.portDiameter / 2)
    case .bottom:
      CGSize(width: 0, height: PolicyCanvasLayout.portDiameter / 2)
    }
  }

  private func offset(
    index: Int,
    count: Int,
    marker: PolicyCanvasPortMarker
  ) -> CGSize {
    switch alignment {
    case .leading, .trailing:
      CGSize(
        width: 0,
        height: PolicyCanvasLayout.portY(index: index, count: count)
          - PolicyCanvasLayout.portDiameter / 2
          + marker.axisOffset
      )
    case .top, .bottom:
      CGSize(
        width: PolicyCanvasLayout.portX(index: index, count: count)
          - PolicyCanvasLayout.portDiameter / 2
          + marker.axisOffset,
        height: 0
      )
    }
  }
}

private struct PolicyCanvasPortPlacement: Identifiable, Equatable {
  let id: String
  let port: PolicyCanvasPort
  let marker: PolicyCanvasPortMarker
  let offset: CGSize
}

private struct PolicyCanvasPortView: View {
  let node: PolicyCanvasNode
  let port: PolicyCanvasPort
  let side: PolicyCanvasPortSide
  let viewModel: PolicyCanvasViewModel
  let isAuxiliary: Bool
  let allowsInteraction: Bool

  var body: some View {
    if !allowsInteraction {
      portMarker
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else if port.kind == .output {
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
        .draggable(viewModel.portDragPayload(nodeID: node.id, portID: port.id, side: side))
        .simultaneousGesture(rubberBandGesture)
    } else {
      portMarker
        .dropDestination(for: String.self) { payloads, _ in
          viewModel.connectDroppedPortPayloads(
            payloads,
            targetNodeID: node.id,
            targetPortID: port.id,
            targetSide: side
          )
        } isTargeted: { targeted in
          viewModel.setInputTargeted(
            targeted,
            nodeID: node.id,
            portID: port.id,
            side: side
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
          viewModel.beginPendingEdge(sourceNodeID: node.id, sourcePortID: port.id, side: side)
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
      kind: port.kind,
      side: side
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
      // Role suffix ("output port" / "input port") tells the VoiceOver user
      // which side of an edge this circle sits on — without it the label is
      // ambiguous ("Policy intake source") between a draggable output and a
      // drop-target input, and the only visual distinguisher is fill color.
      .accessibilityLabel(
        "\(node.title) \(port.title) \(port.kind == .output ? "output port" : "input port")"
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasPort(
          node.id,
          port.id
        )
      )
      .accessibilityHidden(isAuxiliary)
  }
}
