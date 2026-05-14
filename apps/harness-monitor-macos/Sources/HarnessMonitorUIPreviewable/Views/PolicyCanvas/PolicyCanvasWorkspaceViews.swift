import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  @State private var magnifyStartZoom: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

          ZStack(alignment: .topLeading) {
            PolicyCanvasGroupLayer(viewModel: viewModel)
            PolicyCanvasEdgeLayer(viewModel: viewModel)
            PolicyCanvasNodeLayer(viewModel: viewModel)
          }
          .scaleEffect(viewModel.zoom, anchor: .topLeading)
        }
        .frame(
          width: max(proxy.size.width, viewModel.canvasContentSize.width * viewModel.zoom),
          height: max(proxy.size.height, viewModel.canvasContentSize.height * viewModel.zoom),
          alignment: .topLeading
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { payloads, location in
          viewModel.dropPalettePayloads(
            payloads,
            at: viewModel.canvasPoint(for: location)
          )
        }
        .onTapGesture {
          viewModel.select(nil)
        }
      }
      .scrollIndicators(.visible)
      .background(Color(red: 0.03, green: 0.04, blue: 0.06))
      .clipShape(Rectangle())
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .padding(14)
      }
      .simultaneousGesture(magnifyGesture)
    }
    .accessibilityElement(children: .contain)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }

  private var magnifyGesture: some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { value in
        let baseZoom = magnifyStartZoom ?? viewModel.zoom
        if magnifyStartZoom == nil {
          magnifyStartZoom = baseZoom
        }
        viewModel.setZoom(baseZoom * value.magnification)
      }
      .onEnded { _ in
        magnifyStartZoom = nil
      }
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
      ForEach(Array(viewModel.edges.enumerated()), id: \.element.id) { offset, edge in
        if let source = viewModel.portAnchor(for: edge.source),
          let target = viewModel.portAnchor(for: edge.target)
        {
          let route = PolicyCanvasEdgeRoute(
            source: source,
            target: target,
            lane: offset,
            groups: viewModel.groups,
            sourceGroupID: viewModel.node(edge.source.nodeID)?.groupID,
            targetGroupID: viewModel.node(edge.target.nodeID)?.groupID
          )
          PolicyCanvasEdgeShape(route: route)
            .stroke(
              edgeColor(for: edge).opacity(viewModel.selection == .edge(edge.id) ? 0.95 : 0.62),
              style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
            .accessibilityHidden(true)

          Button {
            viewModel.select(.edge(edge.id))
          } label: {
            Text(edge.label)
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(.white.opacity(0.90))
              .lineLimit(1)
              .frame(maxWidth: 138)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.92), in: Capsule())
              .overlay {
                Capsule()
                  .stroke(edgeColor(for: edge).opacity(0.62), lineWidth: 1)
              }
          }
          .harnessPlainButtonStyle()
          .position(route.labelPosition)
          .accessibilityLabel(viewModel.accessibilityLabel(for: edge))
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEdge(edge.id))
        }
      }
    }
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    viewModel.node(edge.source.nodeID)?.kind.accentColor ?? Color.cyan
  }
}

private struct PolicyCanvasEdgeShape: Shape {
  let route: PolicyCanvasEdgeRoute

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard let firstPoint = route.points.first else {
      return path
    }
    path.move(to: firstPoint)
    for point in route.points.dropFirst() {
      path.addLine(to: point)
    }
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
        .scaledFont(.caption.weight(.semibold))
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
          .scaledFont(.system(size: 16, weight: .semibold))
          .foregroundStyle(node.kind.accentColor)
          .frame(width: 24, height: 24)
          .background(node.kind.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 5) {
          Text(node.title)
            .scaledFont(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)

          Text(node.subtitle)
            .scaledFont(.caption)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)

          if let groupID = node.groupID, let group = viewModel.group(groupID) {
            Text(group.title)
              .scaledFont(.caption2.weight(.medium))
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(viewModel.accessibilityLabel(for: node))
    .accessibilityValue(viewModel.accessibilityValue(for: node))
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasNode(node.id))
  }
}
