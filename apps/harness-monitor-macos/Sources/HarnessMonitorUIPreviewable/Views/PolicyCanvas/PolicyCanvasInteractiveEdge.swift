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
  /// Spoken kind word (`"flow"` / `"control"` / `"error"`) surfaced to
  /// VoiceOver via `.accessibilityValue`. Without this, the kind encoding
  /// is color-only and fails WCAG 1.4.1 for users who cannot perceive the
  /// cyan/purple/red palette. Combined with `kindDashPattern`, the kind
  /// becomes both visible (pattern) and audible (value) - color is no
  /// longer the sole differentiator.
  let accessibilityKindWord: String
  /// Static dash pattern bound to the edge kind. Empty for `.flow` (solid
  /// stroke); wider gaps for `.control` (occasional condition); tighter
  /// dashes for `.error` (urgent). When `isAnimated && !reducedMotion`,
  /// the animated overlay supersedes this pattern with its own dash march;
  /// otherwise this pattern is what the user sees.
  let kindDashPattern: [CGFloat]
  let isAnimated: Bool
  /// Canvas zoom factor read from `viewModel.zoom` at the call site. Used
  /// to clamp the dash-march apparent velocity per
  /// `PolicyCanvasEdgeAnimation.effectiveVelocity(canvasZoom:)`. Defaults
  /// to 1.0 so call sites that have not adopted the parameter yet keep
  /// the previous behavior; the canvas-mounted call site passes the live
  /// zoom.
  let canvasZoom: CGFloat
  let onTap: () -> Void
  let onDelete: () -> Void

  @State private var isHovering = false
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  init(
    route: PolicyCanvasEdgeRoute,
    color: Color,
    strokeWidth: CGFloat,
    isSelected: Bool,
    accessibilityLabel: String,
    accessibilityKindWord: String,
    kindDashPattern: [CGFloat] = [],
    isAnimated: Bool = false,
    canvasZoom: CGFloat = 1,
    onTap: @escaping () -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.route = route
    self.color = color
    self.strokeWidth = strokeWidth
    self.isSelected = isSelected
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityKindWord = accessibilityKindWord
    self.kindDashPattern = kindDashPattern
    self.isAnimated = isAnimated
    self.canvasZoom = canvasZoom
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
    .help(hoverHelpString)
    .contextMenu {
      Button("Delete edge", role: .destructive, action: onDelete)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValueString)
    .accessibilityAddTraits(.isButton)
    .accessibilityActivationPoint(route.arcLengthMidpoint)
  }

  /// Hover tooltip surfacing the same kind word a VoiceOver user hears via
  /// `.accessibilityValue`. Without this, sighted users hovering an edge got
  /// only the "from source to target" label while AT users got the kind -
  /// modality asymmetry that left sighted users to decode the color or dash
  /// pattern unaided. The kind is named in parentheses so the existing label
  /// stays the headline.
  private var hoverHelpString: String {
    "\(accessibilityLabel) (\(accessibilityKindWord))"
  }

  /// VoiceOver value combining the kind word with an "active" suffix when
  /// motion is permitted. Without the reduce-motion gate the value would
  /// announce "active" even when the dash march is frozen, leaving the AT
  /// user with a stale model of edge state.
  private var accessibilityValueString: String {
    if isAnimated, !reducedMotion {
      return "\(accessibilityKindWord), active"
    }
    return accessibilityKindWord
  }

  @ViewBuilder private var strokeLayer: some View {
    if isAnimated, !reducedMotion {
      TimelineView(.animation) { context in
        let phase = PolicyCanvasEdgeAnimation.dashPhase(
          at: context.date,
          canvasZoom: canvasZoom
        )
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
            lineJoin: .round,
            dash: kindDashPattern
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

  @MainActor
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

  /// Base dash velocity at 1x canvas zoom. 12pt/sec is one full
  /// dash+gap cycle per second - readable as flow without distracting.
  static let baseVelocityPointsPerSecond: CGFloat = 12

  /// Apparent on-screen velocity ceiling. Watson's R2 WCAG 2.3.3 note:
  /// users on system Zoom 4x-8x without reduce-motion would see the dash
  /// march at 48-96pt/sec without a cap, which approaches the
  /// vestibular-trigger band. 24pt/sec keeps the cue legible at every
  /// zoom level while bounding the on-screen distance the eye tracks per
  /// second.
  static let maxApparentVelocityPointsPerSecond: CGFloat = 24

  /// Compute the dash-phase offset for the current TimelineView tick. Phase
  /// advances `effectiveVelocity(canvasZoom:)` points per second along the
  /// polyline so the dash appears to march at a steady on-screen pace
  /// regardless of canvas zoom level.
  static func dashPhase(at date: Date, canvasZoom: CGFloat = 1) -> CGFloat {
    let cycle = dashPattern.reduce(0, +)
    let velocity = effectiveVelocity(canvasZoom: canvasZoom)
    let elapsed = date.timeIntervalSinceReferenceDate * Double(velocity)
    return -CGFloat(elapsed.truncatingRemainder(dividingBy: Double(cycle)))
  }

  /// Resolve the in-route dash velocity that produces a clamped apparent
  /// on-screen velocity. When `canvasZoom <= 2`, the base 12pt/sec runs
  /// unchanged - apparent velocity scales linearly to 24pt/sec at zoom
  /// 2.0 and stays at the cap from there on. The function clamps to
  /// `0.01` zoom on the low end to keep the division well-defined at
  /// extreme far-zoom.
  static func effectiveVelocity(canvasZoom: CGFloat) -> CGFloat {
    let zoom = max(0.01, canvasZoom)
    let apparent = min(baseVelocityPointsPerSecond * zoom, maxApparentVelocityPointsPerSecond)
    return apparent / zoom
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
