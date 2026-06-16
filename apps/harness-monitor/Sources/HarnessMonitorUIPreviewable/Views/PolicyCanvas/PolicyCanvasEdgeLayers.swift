import AppKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private let policyCanvasAnimatedEdgeTimelineLimit = 24
private let policyCanvasDenseEdgeCanvasLimit = 24
private let policyCanvasSwiftUIEdgeContextMenuLimit = 24

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
  let contentSize: CGSize
  let accessibilityLabelsByEdgeID: [String: String]
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
    let allowsAnimatedEdgeTimelines = edges.count <= policyCanvasAnimatedEdgeTimelineLimit
    let allowsSwiftUIEdgeContextMenus = edges.count <= policyCanvasSwiftUIEdgeContextMenuLimit
    ZStack(alignment: .topLeading) {
      if edges.count > policyCanvasDenseEdgeCanvasLimit {
        PolicyCanvasDenseEdgeCanvas(
          edges: edges,
          routes: routes,
          labelPositions: labelPositions,
          severityMap: severityMap,
          routingHints: routingHints,
          selectedEdgeID: selectedEdgeID,
          metrics: metrics,
          colorScheme: colorScheme,
          canvasZoom: viewModel.zoom
        )
        .frame(
          width: contentSize.width,
          height: contentSize.height,
          alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      } else {
        ForEach(edges) { edge in
          if let route = routes[edge.id] {
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
              isAnimated: edge.isAnimated && allowsAnimatedEdgeTimelines,
              allowsContextMenu: allowsSwiftUIEdgeContextMenus,
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
            .equatable()
          }
        }
      }
    }
  }

  private var selectedEdgeID: String? {
    guard case .edge(let id) = viewModel.selection else {
      return nil
    }
    return id
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

private struct PolicyCanvasDenseEdgeCanvas: View {
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let severityMap: [String: PolicyCanvasIssueSeverity]
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let selectedEdgeID: String?
  let metrics: PolicyCanvasEdgeLabelMetrics
  let colorScheme: ColorScheme
  let canvasZoom: CGFloat

  var body: some View {
    PolicyCanvasDenseEdgeDrawingSurface(items: drawingItems)
  }

  private var drawingItems: [PolicyCanvasDenseEdgeDrawingItem] {
    edges.compactMap { edge in
      guard let route = routes[edge.id] else {
        return nil
      }
      let hint = routingHints?.edgeHint(for: edge.id)
      let bundleOrdinal = hint?.bundleOrdinal ?? 0
      let bundleSize = hint?.bundleSize ?? 1
      let severity = severityMap[edge.id]
      let isSelected = selectedEdgeID == edge.id
      let renderedRoute = policyCanvasEndpointTrimmedRoute(
        route,
        endpointInset: policyCanvasRenderedRouteEndpointInset()
      )
      return PolicyCanvasDenseEdgeDrawingItem(
        route: renderedRoute,
        labelGapFrames: labelGapFrames(edge: edge),
        strokeColor: strokeColor(
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
        strokeWidth: PolicyCanvasEdgeStrokeMetrics.visibleStrokeWidth(
          baseWidth: severity == nil ? 2.0 : 2.4,
          isSelected: isSelected,
          canvasZoom: canvasZoom
        ),
        dashPattern: policyCanvasBundleRailDashPattern(
          kindDashPattern: edge.kind.strokeDashPattern,
          bundleOrdinal: bundleOrdinal,
          bundleSize: bundleSize
        ),
        isSelected: isSelected
      )
    }
  }

  private func labelGapFrames(edge: PolicyCanvasEdge) -> [CGRect] {
    guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
      return []
    }
    return [metrics.frame(for: edge.label, center: position)]
  }

  private func edgeColor(for edge: PolicyCanvasEdge) -> Color {
    edge.kind.accentColor
  }

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
}

private struct PolicyCanvasDenseEdgeDrawingSurface: NSViewRepresentable {
  let items: [PolicyCanvasDenseEdgeDrawingItem]

  func makeNSView(context: Context) -> PolicyCanvasDenseEdgeDrawingView {
    PolicyCanvasDenseEdgeDrawingView()
  }

  func updateNSView(_ nsView: PolicyCanvasDenseEdgeDrawingView, context: Context) {
    nsView.items = items
  }
}

private struct PolicyCanvasDenseEdgeDrawingItem: Equatable {
  let route: PolicyCanvasEdgeRoute
  let labelGapFrames: [CGRect]
  let strokeColor: Color
  let arrowheadColor: Color
  let strokeWidth: CGFloat
  let dashPattern: [CGFloat]
  let isSelected: Bool
}

@MainActor
private final class PolicyCanvasDenseEdgeDrawingView: NSView {
  var items: [PolicyCanvasDenseEdgeDrawingItem] = [] {
    didSet {
      guard items != oldValue else {
        return
      }
      needsDisplay = true
    }
  }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    policyCanvasApplyTransparentDrawingBacking(to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for item in items {
        draw(item)
      }
    }
  }

  private func draw(_ item: PolicyCanvasDenseEdgeDrawingItem) {
    for points in policyCanvasVisibleEdgeSubroutes(
      points: item.route.points,
      gapFrames: item.labelGapFrames
    ) {
      guard let path = policyCanvasAppKitEdgePath(points: points) else {
        continue
      }
      if item.isSelected {
        policyCanvasStroke(
          path,
          color: PolicyCanvasVisualStyle.activeTint,
          alpha: 0.18,
          lineWidth: 5
        )
      }
      policyCanvasStroke(
        path,
        color: item.strokeColor,
        lineWidth: item.strokeWidth,
        dash: item.dashPattern
      )
    }

    if let arrowhead = policyCanvasDenseEdgeArrowheadPath(route: item.route) {
      policyCanvasFill(arrowhead, color: item.arrowheadColor)
    }
  }
}

private func policyCanvasDenseEdgeArrowheadPath(route: PolicyCanvasEdgeRoute) -> NSBezierPath? {
  let points = route.points
  guard points.count >= 2, let tip = points.last else {
    return nil
  }
  let previous = points[points.count - 2]
  let direction = (tip - previous).normalized
  guard direction.length > 0 else {
    return nil
  }
  let length: CGFloat = 12
  let halfWidth: CGFloat = 4.5
  let perpendicular = CGPoint(x: -direction.y, y: direction.x)
  let base = tip - direction * length
  let path = NSBezierPath()
  path.move(to: tip)
  path.line(to: base + perpendicular * halfWidth)
  path.line(to: base - perpendicular * halfWidth)
  path.close()
  return path
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
  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.colorScheme)
  private var colorScheme

  var body: some View {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    ZStack(alignment: .topLeading) {
      ForEach(edges) { edge in
        if !edge.label.isEmpty, let route = routes[edge.id] {
          let labelPosition = labelPositions[edge.id] ?? route.labelPosition
          let labelSize = metrics.size(for: edge.label)
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
                in: RoundedRectangle(
                  cornerRadius: PolicyCanvasVisualStyle.edgeLabelCornerRadius, style: .continuous)
              )
              .overlay {
                RoundedRectangle(
                  cornerRadius: PolicyCanvasVisualStyle.edgeLabelCornerRadius, style: .continuous
                )
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
