import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// View-only flag from the host. The host (`PolicyCanvasView`) auto-flips
  /// this on when a simulation is available and the user is on the
  /// simulation tab; the chrome toggle in the top bar lets the user hide
  /// the overlay even when both conditions hold. Simulation visibility is
  /// purely viewport state — never set `documentDirty` from this seam.
  var showSimulationOverlay: Bool = false
  @State private var magnifyStartZoom: CGFloat?

  var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { scrollProxy in
        ScrollView([.horizontal, .vertical]) {
          ZStack(alignment: .topLeading) {
            PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

            Color.clear
              .frame(width: 1, height: 1)
              .position(viewModel.initialViewportAnchorPoint)
              .id(PolicyCanvasLayout.initialViewportAnchorID)
              .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
              PolicyCanvasGroupLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              PolicyCanvasEdgeLayer(viewModel: viewModel)
              PolicyCanvasRubberBandLayer(viewModel: viewModel)
              PolicyCanvasNodeLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              if showSimulationOverlay {
                PolicyCanvasSimulationLayer(viewModel: viewModel)
              }
              PolicyCanvasEdgeLabelLayer(viewModel: viewModel, focusedComponent: focusedComponent)
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
        .scrollIndicators(.visible)
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
        .clipShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
          PolicyCanvasZoomControls(viewModel: viewModel)
            .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
          PolicyCanvasShortcutsDisclosure()
            .padding(14)
        }
        .simultaneousGesture(magnifyGesture)
        .onAppear {
          centerViewportIfNeeded(scrollProxy)
        }
        .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
          centerViewportIfNeeded(scrollProxy)
        }
      }
    }
    // P57: `.contain` is paired only with `.accessibilityIdentifier` here (no
    // parent label) so the rotor + children stay exposed without the
    // VoiceOver "stops on every child of a labelled element" footgun. Two
    // rotors live below: "Nodes" walks the visual focus order so VO users
    // can hop across the graph; "Edges" lists every wired connection.
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      // P25: rotor entries built lazily from the focus-order id list; we map
      // ids to labels per-iteration so the rotor content closure never
      // captures live node values across frames. Anchoring the rotor entry
      // on the node's identifier delegates ring focus to the
      // `.accessibilityFocused` modifier on the matching node card.
      ForEach(viewModel.accessibilityNodeFocusOrder(), id: \.self) { nodeID in
        if let node = viewModel.node(nodeID) {
          AccessibilityRotorEntry(
            viewModel.accessibilityLabel(for: node),
            id: nodeID
          )
        }
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(viewModel.edges, id: \.id) { edge in
        AccessibilityRotorEntry(
          viewModel.accessibilityLabel(for: edge),
          id: edge.id
        )
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }

  private func centerViewportIfNeeded(_ scrollProxy: ScrollViewProxy) {
    guard viewModel.consumeViewportCenteringRequest() else {
      return
    }
    Task { @MainActor in
      await Task.yield()
      scrollProxy.scrollTo(PolicyCanvasLayout.initialViewportAnchorID, anchor: .center)
    }
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
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding

  var body: some View {
    ForEach(viewModel.groups) { group in
      PolicyCanvasGroupRegion(
        group: group,
        isSelected: viewModel.isSelected(.group(group.id)),
        isHighlighted: viewModel.highlightedGroupID == group.id
      )
      .offset(x: group.frame.minX, y: group.frame.minY)
      .accessibilityFocused(focusedComponent, equals: .group(group.id))
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            viewModel.dragGroup(group.id, translation: value.translation)
          }
          .onEnded { value in
            viewModel.endGroupDrag(group.id, translation: value.translation)
          }
      )
      .simultaneousGesture(
        TapGesture()
          .modifiers(.shift)
          .onEnded {
            viewModel.extendSelection(.group(group.id))
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
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  @Environment(\.fontScale) private var fontScale

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
          .simultaneousGesture(
            TapGesture()
              .modifiers(.shift)
              .onEnded {
                viewModel.extendSelection(.edge(edge.id))
              }
          )
          .accessibilityFocused(focusedComponent, equals: .edge(edge.id))
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

private struct PolicyCanvasEdgeLabelMetrics {
  let horizontalPadding: CGFloat
  let minWidth: CGFloat
  let height: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    horizontalPadding = (12 * scale).rounded(.up)
    minWidth = (88 * scale).rounded(.up)
    height = max(
      PolicyCanvasLayout.edgeLabelHeight,
      (PolicyCanvasLayout.edgeLabelHeight * scale).rounded(.up)
    )
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
