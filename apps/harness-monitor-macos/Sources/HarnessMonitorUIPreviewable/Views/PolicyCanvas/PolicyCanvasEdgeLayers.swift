import SwiftUI

struct PolicyCanvasEdgeLayer: View {
  let viewModel: PolicyCanvasViewModel
  /// Hoisted from the viewport parent's body. Iterating the parameter-bound
  /// `edges` instead of `viewModel.edges` avoids a second `@Observable`
  /// accessor invocation per render (the parent already read it once when
  /// building the `portAnchors` map).
  let edges: [PolicyCanvasEdge]
  /// Bulk port-anchor map computed once in the viewport parent and shared
  /// with `PolicyCanvasEdgeLabelLayer` so the two layers do not each rebuild
  /// the same dictionary per render cycle.
  let portAnchors: [PolicyCanvasPortEndpoint: CGPoint]

  var body: some View {
    // Severity map and edge-lane assignments stay local to this layer:
    // both are layer-specific and the label layer does not need them.
    let severityMap = viewModel.edgeSeverityMap
    let edgeLanes = viewModel.edgeRouteLanes
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if let source = portAnchors[edge.source],
          let target = portAnchors[edge.target]
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

struct PolicyCanvasEdgeLabelLayer: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// Shared with `PolicyCanvasEdgeLayer` via the viewport parent so both
  /// layers iterate the same hoisted array (one `@Observable` read instead
  /// of one read per layer).
  let edges: [PolicyCanvasEdge]
  /// Shared bulk port-anchor map built once in the viewport parent — see
  /// `PolicyCanvasEdgeLayer` for the dedup rationale.
  let portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let edgeLanes = viewModel.edgeRouteLanes
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if !edge.label.isEmpty,
          let source = portAnchors[edge.source],
          let target = portAnchors[edge.target]
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
  var cornerRadius: CGFloat = 7

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points = route.points
    guard let first = points.first else {
      return path
    }
    path.move(to: first)
    guard points.count >= 3 else {
      for point in points.dropFirst() {
        path.addLine(to: point)
      }
      return path
    }
    for index in 1 ..< points.count - 1 {
      let previous = points[index - 1]
      let current = points[index]
      let next = points[index + 1]
      let inUnit = (current - previous).normalized
      let outUnit = (next - current).normalized
      let radius = min(
        cornerRadius,
        min((current - previous).length, (next - current).length) / 2
      )
      path.addLine(to: current - inUnit * radius)
      path.addQuadCurve(to: current + outUnit * radius, control: current)
    }
    if let last = points.last {
      path.addLine(to: last)
    }
    return path
  }
}
