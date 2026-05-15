import SwiftUI

/// Wraps the visible edge stroke, arrowhead, optional selection halo, and a
/// fat invisible hit area. Solves three problems with the bare-stroke layer:
/// 1. The stroke was `accessibilityHidden(true)` and had no tap target -
///    unlabeled edges had no mouse selection path at all.
/// 2. Selection used a 12% opacity delta that disappeared on a busy canvas.
/// 3. Direction was not encoded; arrowhead now carries it.
struct PolicyCanvasInteractiveEdge: View {
  let route: PolicyCanvasEdgeRoute
  let color: Color
  let strokeWidth: CGFloat
  let isSelected: Bool
  let accessibilityLabel: String
  let isAnimated: Bool
  let onTap: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false
  @Environment(\.policyCanvasReducedMotion) private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  init(
    route: PolicyCanvasEdgeRoute,
    color: Color,
    strokeWidth: CGFloat,
    isSelected: Bool,
    accessibilityLabel: String,
    isAnimated: Bool = false,
    onTap: @escaping () -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.route = route
    self.color = color
    self.strokeWidth = strokeWidth
    self.isSelected = isSelected
    self.accessibilityLabel = accessibilityLabel
    self.isAnimated = isAnimated
    self.onTap = onTap
    self.onDelete = onDelete
  }

  var body: some View {
    ZStack {
      if isSelected {
        PolicyCanvasEdgeShape(route: route)
          .stroke(
            color.opacity(0.35),
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
          )
          .allowsHitTesting(false)
          .blendMode(.plusLighter)
      }
      strokeLayer
      PolicyCanvasEdgeArrowhead(route: route)
        .fill(color)
    }
    .contentShape(PolicyCanvasEdgeHitShape(route: route))
    .onHover { isHovering = $0 }
    .onTapGesture(perform: onTap)
    .help(accessibilityLabel)
    .contextMenu {
      Button("Delete edge", role: .destructive, action: onDelete)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private var strokeLayer: some View {
    if isAnimated, !reducedMotion {
      TimelineView(.animation) { context in
        let phase = PolicyCanvasEdgeAnimation.dashPhase(at: context.date)
        PolicyCanvasEdgeShape(route: route)
          .stroke(
            color,
            style: StrokeStyle(
              lineWidth: effectiveStrokeWidth,
              lineCap: .round,
              lineJoin: .round,
              dash: PolicyCanvasEdgeAnimation.dashPattern,
              dashPhase: phase
            )
          )
      }
    } else {
      PolicyCanvasEdgeShape(route: route)
        .stroke(
          color,
          style: StrokeStyle(
            lineWidth: effectiveStrokeWidth,
            lineCap: .round,
            lineJoin: .round
          )
        )
    }
  }

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  private var effectiveStrokeWidth: CGFloat {
    if isSelected {
      return strokeWidth + 1.0
    }
    if isHovering {
      return strokeWidth + 0.4
    }
    return strokeWidth
  }

  static var animatedDashPattern: [CGFloat] {
    PolicyCanvasEdgeAnimation.dashPattern
  }

  static func animatedDashPhase(at date: Date) -> CGFloat {
    PolicyCanvasEdgeAnimation.dashPhase(at: date)
  }
}

/// Non-View animation helpers for `PolicyCanvasInteractiveEdge`. Lives
/// outside the View hierarchy so unit tests can call `dashPhase(at:)` from a
/// non-MainActor context.
enum PolicyCanvasEdgeAnimation {
  /// Dash pattern for animated flow edges. 8pt dash + 4pt gap reads as a
  /// directional flow at default zoom without sliding off the polyline at
  /// fast frame rates.
  static let dashPattern: [CGFloat] = [8, 4]

  /// Compute the dash-phase offset for the current TimelineView tick. Phase
  /// advances 12pt per second (one full dash+gap cycle) so the dash appears
  /// to march along the polyline at a steady pace.
  static func dashPhase(at date: Date) -> CGFloat {
    let cycle = dashPattern.reduce(0, +)
    let elapsed = date.timeIntervalSinceReferenceDate * 12
    return -CGFloat(elapsed.truncatingRemainder(dividingBy: Double(cycle)))
  }
}

/// Fat stroked version of the route polyline used purely for hit-testing.
/// Never rendered - `.contentShape` consumes the geometry without drawing.
struct PolicyCanvasEdgeHitShape: Shape {
  let route: PolicyCanvasEdgeRoute
  var lineWidth: CGFloat = 12

  func path(in rect: CGRect) -> Path {
    PolicyCanvasEdgeShape(route: route)
      .path(in: rect)
      .strokedPath(
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
      )
  }
}
