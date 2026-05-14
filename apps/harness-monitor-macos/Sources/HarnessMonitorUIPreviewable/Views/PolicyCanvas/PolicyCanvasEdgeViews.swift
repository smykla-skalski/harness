import SwiftUI

/// Edge-drawing layers extracted from `PolicyCanvasWorkspaceViews.swift` on
/// touch (Wave 4L fix-up) so the workspace file stays under the 420-line
/// cap after the reduce-motion env reads landed on every layer.
///
/// `PolicyCanvasEdgeLayer` renders the connection strokes; the matching
/// label layer (`PolicyCanvasEdgeLabelLayer`) paints clickable capsules
/// over each route's label midpoint so labels stay legible and selectable
/// even when edges visually overlap at a route junction.
struct PolicyCanvasEdgeLayer: View {
  let viewModel: PolicyCanvasViewModel
  /// P19 reduce-motion handle for the P18 edge selection-mark transition.
  /// Canvas-scoped override is optional with system fallback; see
  /// `PolicyCanvasMotion`.
  @Environment(\.policyCanvasReducedMotion) private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  var body: some View {
    let severityMap = viewModel.edgeSeverityMap
    let edgeLanes = viewModel.edgeRouteLanes
    let selectedEdgeID = viewModel.selectedEdge?.id
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
            // P18 edge selection-mark: fade the stroke color when the
            // selection landing on this edge flips. Keyed on the
            // edge-vs-selected match bit so neighboring edges don't reanimate
            // when an unrelated selection change repaints the layer. The
            // wrapper hoists the `Animation?` value out of the body so the
            // per-frame construction collapses to a `static let` lookup.
            .policyCanvasSelectionMark(
              value: selectedEdgeID == edge.id,
              reducedMotion: reducedMotion
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

struct PolicyCanvasEdgeLabelLayer: View {
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

struct PolicyCanvasEdgeLabelMetrics {
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

struct PolicyCanvasEdgeShape: Shape {
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
