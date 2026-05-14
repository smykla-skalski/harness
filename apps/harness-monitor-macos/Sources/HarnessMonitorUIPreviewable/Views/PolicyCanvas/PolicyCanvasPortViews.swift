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
      portMarker
        .draggable(viewModel.portDragPayload(nodeID: node.id, portID: port.id))
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
