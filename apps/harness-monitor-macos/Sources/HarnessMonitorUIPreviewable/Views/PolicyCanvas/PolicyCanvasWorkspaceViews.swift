import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    GeometryReader { _ in
      ZStack(alignment: .topLeading) {
        PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

        ZStack(alignment: .topLeading) {
          PolicyCanvasGroupLayer(viewModel: viewModel)
          PolicyCanvasEdgeLayer(viewModel: viewModel)
          PolicyCanvasNodeLayer(viewModel: viewModel)
        }
        .scaleEffect(viewModel.zoom, anchor: .topLeading)
      }
      .contentShape(Rectangle())
      .dropDestination(for: String.self) { payloads, location in
        viewModel.dropPalettePayloads(
          payloads,
          at: viewModel.canvasPoint(for: location)
        )
      }
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .padding(14)
      }
      .onTapGesture {
        viewModel.select(nil)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasViewport)
  }
}

private struct PolicyCanvasDottedGrid: View {
  let spacing: CGFloat

  var body: some View {
    Canvas { context, size in
      let dot = Path(
        ellipseIn: CGRect(
          x: 0,
          y: 0,
          width: 1.5,
          height: 1.5
        )
      )
      let xValues = stride(from: CGFloat(0), through: size.width, by: max(8, spacing))
      let yValues = stride(from: CGFloat(0), through: size.height, by: max(8, spacing))
      for x in xValues {
        for y in yValues {
          context.translateBy(x: x, y: y)
          context.fill(dot, with: .color(.white.opacity(0.13)))
          context.translateBy(x: -x, y: -y)
        }
      }
    }
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.06, green: 0.07, blue: 0.10),
          Color(red: 0.03, green: 0.04, blue: 0.06),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}

private struct PolicyCanvasGroupLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ForEach(viewModel.groups) { group in
      PolicyCanvasGroupRegion(
        group: group,
        isSelected: viewModel.selection == .group(group.id),
        isHighlighted: viewModel.highlightedGroupID == group.id
      )
      .offset(x: group.frame.minX, y: group.frame.minY)
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragGroup(group.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endGroupDrag(group.id, translation: value.translation)
          }
      )
      .onTapGesture {
        viewModel.select(.group(group.id))
      }
    }
  }
}

private struct PolicyCanvasEdgeLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(viewModel.edges) { edge in
        if let source = viewModel.portAnchor(for: edge.source),
          let target = viewModel.portAnchor(for: edge.target)
        {
          PolicyCanvasEdgeShape(source: source, target: target)
            .stroke(
              edgeColor(for: edge).opacity(viewModel.selection == .edge(edge.id) ? 0.95 : 0.62),
              style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
            .accessibilityHidden(true)

          Button {
            viewModel.select(.edge(edge.id))
          } label: {
            Text(edge.label)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.white.opacity(0.90))
              .lineLimit(1)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(.black.opacity(0.58), in: Capsule())
              .overlay {
                Capsule()
                  .stroke(edgeColor(for: edge).opacity(0.50), lineWidth: 1)
              }
          }
          .harnessPlainButtonStyle()
          .position(labelPosition(source: source, target: target))
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEdge(edge.id))
        }
      }
    }
  }

  private func labelPosition(source: CGPoint, target: CGPoint) -> CGPoint {
    CGPoint(
      x: (source.x + target.x) / 2,
      y: (source.y + target.y) / 2 - 14
    )
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    viewModel.node(edge.source.nodeID)?.kind.accentColor ?? Color.cyan
  }
}

private struct PolicyCanvasEdgeShape: Shape {
  let source: CGPoint
  let target: CGPoint

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let distance = max(72, abs(target.x - source.x) * 0.42)
    path.move(to: source)
    path.addCurve(
      to: target,
      control1: CGPoint(x: source.x + distance, y: source.y),
      control2: CGPoint(x: target.x - distance, y: target.y)
    )
    return path
  }
}

private struct PolicyCanvasGroupRegion: View {
  let group: PolicyCanvasGroup
  let isSelected: Bool
  let isHighlighted: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
        .fill(group.tone.color.opacity(isHighlighted ? 0.24 : 0.16))
        .overlay {
          RoundedRectangle(cornerRadius: PolicyCanvasLayout.groupCornerRadius)
            .stroke(
              group.tone.color.opacity(isSelected || isHighlighted ? 0.88 : 0.42),
              style: StrokeStyle(lineWidth: isSelected ? 1.6 : 1, dash: [6, 5])
            )
        }

      Text(group.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(group.tone.color.opacity(0.95))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.34), in: Capsule())
        .padding(10)
    }
    .frame(width: group.frame.width, height: group.frame.height)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGroup(group.id))
  }
}

private struct PolicyCanvasNodeLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ForEach(viewModel.nodes) { node in
      PolicyCanvasNodeCard(
        node: node,
        isSelected: viewModel.selection == .node(node.id),
        viewModel: viewModel
      )
      .offset(x: node.position.x, y: node.position.y)
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragNode(node.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endNodeDrag(node.id, translation: value.translation)
          }
      )
      .onTapGesture {
        viewModel.select(.node(node.id))
      }
    }
  }
}

private struct PolicyCanvasNodeCard: View {
  let node: PolicyCanvasNode
  let isSelected: Bool
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(red: 0.10, green: 0.12, blue: 0.16).opacity(0.95))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(node.kind.accentColor.opacity(isSelected ? 0.95 : 0.34), lineWidth: 1.2)
        }
        .shadow(color: .black.opacity(0.34), radius: 12, x: 0, y: 8)

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: node.kind.symbolName)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(node.kind.accentColor)
          .frame(width: 24, height: 24)
          .background(node.kind.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 5) {
          Text(node.title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(node.subtitle)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)

          if let groupID = node.groupID, let group = viewModel.group(groupID) {
            Text(group.title)
              .font(.caption2.weight(.medium))
              .foregroundStyle(group.tone.color.opacity(0.95))
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)
      }
      .padding(12)

      PolicyCanvasPortColumn(
        node: node,
        ports: node.inputPorts,
        alignment: .leading,
        viewModel: viewModel
      )

      PolicyCanvasPortColumn(
        node: node,
        ports: node.outputPorts,
        alignment: .trailing,
        viewModel: viewModel
      )
    }
    .frame(width: PolicyCanvasLayout.nodeSize.width, height: PolicyCanvasLayout.nodeSize.height)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(node.title)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasNode(node.id))
  }
}

private enum PolicyCanvasPortColumnAlignment {
  case leading
  case trailing
}

private struct PolicyCanvasPortColumn: View {
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
