import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasEdgeLayer: View {
  let viewModel: PolicyCanvasViewModel
  /// Focus binding passed from the canvas root so the stroke layer owns
  /// the rotor entry per edge. Watson R1 sev1: previously the stroke and
  /// label both exposed the same accessible name, giving VoiceOver two
  /// entries per labelled edge; the label is now `.accessibilityHidden`
  /// and this binding lives on the stroke.
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// Hoisted from the viewport parent's body. Iterating the parameter-bound
  /// `edges` instead of `viewModel.edges` avoids a second `@Observable`
  /// accessor invocation per render (the parent already read it once when
  /// building the displayed-route map).
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let accessibilityLabelsByEdgeID: [String: String]
  let observationStore: PolicyCanvasViewportObservationStore
  let viewportIdentity: String?
  let openEditor: @MainActor (PolicyCanvasEditSheet) -> Void
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    // Severity map and edge-lane assignments stay local to this layer:
    // both are layer-specific and the label layer does not need them.
    let severityMap = viewModel.edgeSeverityMap
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let routingHints = viewModel.routingHints
    let cullRect = policyCanvasViewportCullRect(
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if let route = routes[edge.id], policyCanvasRouteIsVisible(route, in: cullRect) {
          let severity = severityMap[edge.id]
          let isSelected = viewModel.selection == .edge(edge.id)
          let hint = routingHints?.edgeHint(for: edge.id)
          let bundleOrdinal = hint?.bundleOrdinal ?? 0
          let bundleSize = hint?.bundleSize ?? 1
          let labelGapFrames = policyCanvasLabelGapFrames(
            edge: edge,
            position: labelPositions[edge.id],
            metrics: metrics
          )
          PolicyCanvasInteractiveEdge(
            route: route,
            labelGapFrames: labelGapFrames,
            color: strokeColor(
              for: edge,
              severity: severity,
              isSelected: isSelected,
              bundleOrdinal: bundleOrdinal,
              bundleSize: bundleSize
            ),
            arrowheadColor: arrowheadColor(
              for: edge,
              severity: severity,
              isSelected: isSelected,
              bundleOrdinal: bundleOrdinal,
              bundleSize: bundleSize
            ),
            strokeWidth: severity == nil ? 2.0 : 2.4,
            isSelected: isSelected,
            accessibilityLabel: accessibilityLabelsByEdgeID[edge.id]
              ?? viewModel.accessibilityLabel(for: edge),
            accessibilityKindWord: edge.kind.accessibilityWord,
            accessibilityDashDescription: edge.kind.dashDescription,
            kindDashPattern: policyCanvasBundleRailDashPattern(
              kindDashPattern: edge.kind.strokeDashPattern,
              bundleOrdinal: bundleOrdinal,
              bundleSize: bundleSize
            ),
            isAnimated: edge.isAnimated,
            canvasZoom: viewModel.zoom,
            accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasEdge(edge.id),
            accessibilityFocusBinding: focusedComponent,
            accessibilityFocusValue: .edge(edge.id),
            onTap: { viewModel.select(.edge(edge.id)) },
            onDoubleTap: {
              viewModel.select(.edge(edge.id))
              openEditor(.edge(edge.id))
            },
            onDelete: { viewModel.deleteEdge(edge.id) }
          )
        }
      }
    }
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    edge.kind.accentColor
  }

  /// Severity-aware stroke color. When the edge has at least one resolved
  /// validation issue the stroke flips to the issue's accent tone (red for
  /// errors, yellow for warnings) so the inline mark stays in sync with the
  /// panel. Pulls severity from the body-local map so per-edge lookups stay
  /// O(1). Default opacity 0.78 meets WCAG 1.4.11 (~3:1 on the dark canvas);
  /// selection emphasis now comes from the halo + stroke-width bump in
  /// `PolicyCanvasInteractiveEdge`, so the unselected/selected color delta
  /// stays small.
  private func strokeColor(
    for edge: PolicyCanvasEdge,
    severity: PolicyCanvasIssueSeverity?,
    isSelected: Bool,
    bundleOrdinal: Int,
    bundleSize: Int
  ) -> Color {
    let opacity = PolicyCanvasVisualStyle.edgeStrokeOpacity(colorScheme, isSelected: isSelected)
    if let severity {
      return severity.accentColor.opacity(opacity)
    }
    let hueOffset = policyCanvasBundleHueOffsetDegrees(
      bundleOrdinal: bundleOrdinal,
      bundleSize: bundleSize
    )
    let shifted = policyCanvasBundleHueRotated(edgeColor(for: edge), by: hueOffset)
    return shifted.opacity(opacity)
  }

  /// Arrowhead fill color. Higher opacity than the stroke counterpart so
  /// the 9pt × 7pt filled triangle reads as visually distinct from the
  /// line it sits on. A filled shape at the same alpha as a stroke on a
  /// dark canvas reads ~30% lighter, so the arrowhead would otherwise
  /// disappear into the stroke at busy-canvas density. The bump (0.95
  /// for unselected, 1.0 for selected) keeps direction legible without
  /// shouting.
  private func arrowheadColor(
    for edge: PolicyCanvasEdge,
    severity: PolicyCanvasIssueSeverity?,
    isSelected: Bool,
    bundleOrdinal: Int,
    bundleSize: Int
  ) -> Color {
    let opacity = PolicyCanvasVisualStyle.edgeArrowOpacity(colorScheme, isSelected: isSelected)
    if let severity {
      return severity.accentColor.opacity(opacity)
    }
    let hueOffset = policyCanvasBundleHueOffsetDegrees(
      bundleOrdinal: bundleOrdinal,
      bundleSize: bundleSize
    )
    let shifted = policyCanvasBundleHueRotated(edgeColor(for: edge), by: hueOffset)
    return shifted.opacity(opacity)
  }

  private func policyCanvasLabelGapFrames(
    edge: PolicyCanvasEdge,
    position: CGPoint?,
    metrics: PolicyCanvasEdgeLabelMetrics
  ) -> [CGRect] {
    guard !edge.label.isEmpty, let position else {
      return []
    }
    return [metrics.frame(for: edge.label, center: position)]
  }
}

struct PolicyCanvasEdgeLabelLayer: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// Shared with `PolicyCanvasEdgeLayer` via the viewport parent so both
  /// layers iterate the same hoisted array (one `@Observable` read instead
  /// of one read per layer).
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let observationStore: PolicyCanvasViewportObservationStore
  let viewportIdentity: String?
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let cullRect = policyCanvasViewportCullRect(
      observationStore: observationStore,
      viewportIdentity: viewportIdentity
    )
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if !edge.label.isEmpty, let route = routes[edge.id] {
          let labelPosition = labelPositions[edge.id] ?? route.labelPosition
          let labelSize = metrics.size(for: edge.label)
          if policyCanvasLabelIsVisible(center: labelPosition, size: labelSize, in: cullRect) {
            Button {
            viewModel.select(.edge(edge.id))
          } label: {
            Text(edge.label)
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
              .lineLimit(1)
              .truncationMode(.middle)
              .padding(.horizontal, metrics.horizontalPadding)
              .frame(
                width: labelSize.width,
                height: labelSize.height
              )
              .contentShape(Rectangle())
              .background(
                PolicyCanvasVisualStyle.edgeLabelBackground(edge.kind, colorScheme: colorScheme),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
              }
          }
          .harnessPlainButtonStyle()
          .position(labelPosition)
          // Stroke owns the rotor entry per edge; the label stays clickable
          // for sighted users but the a11y tree only carries it once.
          .accessibilityHidden(true)
          .contextMenu {
            Button("Delete edge", role: .destructive) {
              viewModel.deleteEdge(edge.id)
            }
          }
          }
        }
      }
    }
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    edge.kind.accentColor
  }
}

struct PolicyCanvasEdgeShape: Shape {
  let route: PolicyCanvasEdgeRoute
  var gapFrames: [CGRect] = []
  var cornerRadius: CGFloat = 7

  func path(in rect: CGRect) -> Path {
    if !gapFrames.isEmpty {
      return policyCanvasGappedEdgePath(
        route: route,
        gapFrames: gapFrames,
        cornerRadius: cornerRadius
      )
    }
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
    for index in 1..<points.count - 1 {
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
