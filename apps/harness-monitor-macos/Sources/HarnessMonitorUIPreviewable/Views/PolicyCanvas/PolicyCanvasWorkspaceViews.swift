import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  @State private var magnifyStartZoom: CGFloat?
  @State private var scrollPosition = ScrollPosition()
  @State private var currentModifiers: EventModifiers = []
  @State private var hoveredViewportPoint: CGPoint?
  @State private var isRestoringCommandScrollPosition = false

  var body: some View {
    GeometryReader { proxy in
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

          ZStack(alignment: .topLeading) {
            PolicyCanvasGroupLayer(viewModel: viewModel)
            PolicyCanvasEdgeLayer(viewModel: viewModel)
            PolicyCanvasRubberBandLayer(viewModel: viewModel)
            PolicyCanvasNodeLayer(viewModel: viewModel)
            PolicyCanvasEdgeLabelLayer(viewModel: viewModel)
          }
          .scaleEffect(viewModel.zoom, anchor: .topLeading)
          .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
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
        .overlay {
          PolicyCanvasEmptyStatePlaceholder(viewModel: viewModel)
            .allowsHitTesting(false)
        }
      }
      .scrollPosition($scrollPosition)
      .scrollIndicators(.visible)
      .background(Color(red: 0.03, green: 0.04, blue: 0.06))
      .clipShape(Rectangle())
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .padding(14)
      }
      .simultaneousGesture(magnifyGesture)
      .onModifierKeysChanged(mask: .command, initial: true) { _, newModifiers in
        currentModifiers = newModifiers
      }
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          hoveredViewportPoint = location
        case .ended:
          hoveredViewportPoint = nil
        }
      }
      .onScrollGeometryChange(
        for: CGPoint.self,
        of: \.contentOffset
      ) { oldOffset, newOffset in
        handleScrollOffsetChange(
          oldOffset: oldOffset,
          newOffset: newOffset,
          viewportSize: proxy.size
        )
      }
      .onAppear {
        restoreViewportPosition(for: proxy.size)
      }
      .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
        restoreViewportPosition(for: proxy.size)
      }
      .onChange(of: scrollPosition, initial: false) { _, newPosition in
        if let point = newPosition.point {
          viewModel.viewportScrollPoint = point
        }
      }
      .onChange(of: proxy.size, initial: false) { _, newSize in
        if viewModel.consumeViewportCenteringRequest() {
          centerViewport(for: newSize)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }

  private func restoreViewportPosition(for viewportSize: CGSize) {
    if viewModel.consumeViewportCenteringRequest() {
      centerViewport(for: viewportSize)
      return
    }
    if let point = viewModel.viewportScrollPoint {
      scrollPosition = ScrollPosition(point: point)
    }
  }

  private func centerViewport(for viewportSize: CGSize) {
    let point = viewModel.initialViewportScrollPoint(for: viewportSize)
    viewModel.viewportScrollPoint = point
    scrollPosition = ScrollPosition(point: point)
  }

  private func handleScrollOffsetChange(
    oldOffset: CGPoint,
    newOffset: CGPoint,
    viewportSize: CGSize
  ) {
    if isRestoringCommandScrollPosition {
      isRestoringCommandScrollPosition = false
      return
    }
    guard
      let deltaY = policyCanvasCommandScrollDeltaY(
        isCommandModified: currentModifiers.contains(.command),
        oldOffset: oldOffset,
        newOffset: newOffset
      )
    else {
      return
    }
    let location =
      hoveredViewportPoint
      ?? CGPoint(
        x: viewportSize.width / 2,
        y: viewportSize.height / 2
      )
    zoomByCommandScroll(
      deltaY: deltaY,
      location: location,
      scrollPoint: oldOffset,
      viewportSize: viewportSize
    )
  }

  private func zoomByCommandScroll(
    deltaY: CGFloat,
    location: CGPoint,
    scrollPoint: CGPoint? = nil,
    viewportSize: CGSize
  ) {
    let oldZoom = viewModel.zoom
    let currentScrollPoint =
      scrollPoint ?? viewModel.viewportScrollPoint ?? scrollPosition.point ?? .zero
    let canvasPoint = CGPoint(
      x: (currentScrollPoint.x + location.x) / oldZoom,
      y: (currentScrollPoint.y + location.y) / oldZoom
    )
    guard viewModel.zoomByCommandScroll(deltaY: deltaY) else {
      return
    }
    let nextScrollPoint = viewModel.viewportScrollPoint(
      keepingCanvasPoint: canvasPoint,
      atViewportPoint: location,
      viewportSize: viewportSize
    )
    viewModel.viewportScrollPoint = nextScrollPoint
    isRestoringCommandScrollPosition = true
    scrollPosition = ScrollPosition(point: nextScrollPoint)
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

func policyCanvasCommandScrollDeltaY(
  isCommandModified: Bool,
  oldOffset: CGPoint,
  newOffset: CGPoint
) -> CGFloat? {
  guard isCommandModified else {
    return nil
  }
  let deltaY = oldOffset.y - newOffset.y
  if abs(deltaY) >= 0.1 {
    return deltaY
  }
  let deltaX = oldOffset.x - newOffset.x
  if abs(deltaX) >= 0.1 {
    return deltaX
  }
  return nil
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
      .position(x: group.frame.midX, y: group.frame.midY)
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
      .dropDestination(for: String.self) { payloads, _ in
        viewModel.dropPalettePayloads(
          payloads,
          at: CGPoint(x: group.frame.midX, y: group.frame.midY)
        )
      } isTargeted: { targeted in
        viewModel.setGroupDropTargeted(targeted, groupID: group.id)
      }
    }
  }
}

private struct PolicyCanvasEdgeLayer: View {
  let viewModel: PolicyCanvasViewModel

  var body: some View {
    let severityMap = viewModel.edgeSeverityMap
    let edgeLanes = viewModel.edgeRouteLanes
    ZStack(alignment: .topLeading) {
      ForEach(viewModel.edges) { edge in
        if let source = viewModel.portAnchor(for: edge.source),
          let target = viewModel.portAnchor(for: edge.target)
        {
          let route = PolicyCanvasEdgeRoute(
            source: source,
            target: target,
            lane: edgeLanes[edge.id, default: 0],
            groups: viewModel.groups,
            sourceGroupID: viewModel.node(edge.source.nodeID)?.groupID,
            targetGroupID: viewModel.node(edge.target.nodeID)?.groupID
          )
          let severity = severityMap[edge.id]
          PolicyCanvasEdgeShape(route: route)
            .stroke(
              strokeColor(for: edge, severity: severity),
              style: StrokeStyle(
                lineWidth: severity == nil ? 2.2 : 3.0,
                lineCap: .round,
                lineJoin: .round
              )
            )
            .accessibilityHidden(true)
        }
      }
    }
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    viewModel.node(edge.source.nodeID)?.kind.accentColor ?? Color.cyan
  }

  /// Severity-aware stroke color. When the edge has at least one resolved
  /// validation issue the stroke flips to the issue's accent tone (red for
  /// errors, yellow for warnings) so the inline mark stays in sync with the
  /// panel. Selection still bumps opacity for affordance feedback. Pulls
  /// severity from the body-local map so per-edge lookups stay O(1).
  private func strokeColor(
    for edge: PolicyCanvasEdge,
    severity: PolicyCanvasIssueSeverity?
  ) -> Color {
    let selected = viewModel.selection == .edge(edge.id)
    if let severity {
      return severity.accentColor.opacity(selected ? 0.98 : 0.82)
    }
    return edgeColor(for: edge).opacity(selected ? 0.95 : 0.62)
  }
}

private struct PolicyCanvasEdgeLabelLayer: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let edgeLanes = viewModel.edgeRouteLanes
    ZStack(alignment: .topLeading) {
      ForEach(viewModel.edges) { edge in
        if !edge.label.isEmpty,
          let source = viewModel.portAnchor(for: edge.source),
          let target = viewModel.portAnchor(for: edge.target)
        {
          let route = PolicyCanvasEdgeRoute(
            source: source,
            target: target,
            lane: edgeLanes[edge.id, default: 0],
            groups: viewModel.groups,
            sourceGroupID: viewModel.node(edge.source.nodeID)?.groupID,
            targetGroupID: viewModel.node(edge.target.nodeID)?.groupID
          )
          Button {
            viewModel.select(.edge(edge.id))
          } label: {
            Text(edge.label)
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(.white.opacity(0.92))
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.horizontal, metrics.horizontalPadding)
              .frame(
                minWidth: metrics.minWidth,
                maxWidth: PolicyCanvasLayout.edgeLabelMaxWidth,
                minHeight: metrics.height
              )
              .background(Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.96), in: Capsule())
              .overlay {
                Capsule()
                  .stroke(edgeColor(for: edge).opacity(0.72), lineWidth: 1.2)
              }
          }
          .harnessPlainButtonStyle()
          .position(route.labelPosition)
          .accessibilityLabel(viewModel.accessibilityLabel(for: edge))
          .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEdge(edge.id))
          .contextMenu {
            Button("Delete edge", role: .destructive) {
              viewModel.deleteEdge(edge.id)
            }
          }
        }
      }
    }
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    viewModel.node(edge.source.nodeID)?.kind.accentColor ?? Color.cyan
  }

}
