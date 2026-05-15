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
  /// Fill color for the direction arrowhead. Caller bumps this above the
  /// stroke alpha so the 9pt × 7pt filled triangle reads as visually
  /// distinct from the line it terminates. A filled shape on a dark
  /// canvas needs more alpha than a stroke to land at the same
  /// perceptual weight (Bertin's retinal-variable weighting), so the
  /// stroke alpha at 0.78 makes a same-alpha arrowhead feel ~30%
  /// lighter than the line.
  let arrowheadColor: Color
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
  /// Plain-English name for the static dash pattern, surfaced to sighted
  /// users in the hover tooltip and to AT users in the legend swatch
  /// `accessibilityLabel`. Drawn from `PolicyCanvasEdgeKind.dashDescription` at the
  /// call site so the legend and the tooltip share one vocabulary instead
  /// of three.
  let accessibilityDashDescription: String
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
  /// Stable a11y identifier shared with the visible label capsule (or
  /// collapsed dot) that this stroke layers above. The stroke owns the
  /// rotor entry per WCAG 4.1.2: previously both the stroke and the label
  /// exposed the same accessibility label, so VoiceOver announced every
  /// edge twice. Now the label is `.accessibilityHidden(true)` and this
  /// identifier sits on the stroke instead.
  let accessibilityIdentifier: String
  /// Focus binding the canvas uses to reveal the selected edge to
  /// VoiceOver. Plumbed onto the stroke (the sole rotor entry) so a focus
  /// restore from search or selection lands on the same element a rotor
  /// walk would reach.
  let accessibilityFocusBinding: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  /// Selection value the focus binding is compared against to determine
  /// whether this stroke owns AT focus.
  let accessibilityFocusValue: PolicyCanvasSelection
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
    arrowheadColor: Color? = nil,
    strokeWidth: CGFloat,
    isSelected: Bool,
    accessibilityLabel: String,
    accessibilityKindWord: String,
    accessibilityDashDescription: String,
    kindDashPattern: [CGFloat] = [],
    isAnimated: Bool = false,
    canvasZoom: CGFloat = 1,
    accessibilityIdentifier: String,
    accessibilityFocusBinding: AccessibilityFocusState<PolicyCanvasSelection?>.Binding,
    accessibilityFocusValue: PolicyCanvasSelection,
    onTap: @escaping () -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.route = route
    self.color = color
    self.arrowheadColor = arrowheadColor ?? color
    self.strokeWidth = strokeWidth
    self.isSelected = isSelected
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityKindWord = accessibilityKindWord
    self.accessibilityDashDescription = accessibilityDashDescription
    self.kindDashPattern = kindDashPattern
    self.isAnimated = isAnimated
    self.canvasZoom = canvasZoom
    self.accessibilityIdentifier = accessibilityIdentifier
    self.accessibilityFocusBinding = accessibilityFocusBinding
    self.accessibilityFocusValue = accessibilityFocusValue
    self.onTap = onTap
    self.onDelete = onDelete
  }

  var body: some View {
    ZStack {
      if isSelected {
        PolicyCanvasEdgeShape(route: route)
          .stroke(
            selectionHaloColor,
            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
          )
          .allowsHitTesting(false)
          .blendMode(.plusLighter)
      }
      strokeLayer
      PolicyCanvasEdgeArrowhead(route: route)
        .fill(arrowheadColor)
    }
    .contentShape(PolicyCanvasEdgeHitShape(route: route))
    .onHover { isHovering = $0 }
    .onTapGesture(perform: onTap)
    .help(hoverHelpString)
    .contextMenu {
      Button("Delete edge", role: .destructive, action: onDelete)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFocused(accessibilityFocusBinding, equals: accessibilityFocusValue)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValueString)
    .accessibilityAddTraits(.isButton)
    .accessibilityActivationPoint(route.arcLengthMidpoint)
  }

  /// Selection halo color. Sourced from the system accent rather than
  /// the edge's own hue so the highlight reads as "selected" on every
  /// kind. With the prior `color.opacity(0.35)` formula a selected
  /// `.error` edge produced a red halo around a red stroke - selection
  /// was nearly invisible. Pulling from `Color.accentColor` keeps the
  /// halo distinct from cyan flow, purple control, and red error
  /// strokes alike.
  private var selectionHaloColor: Color {
    Color.accentColor.opacity(0.30)
  }

  /// Hover tooltip surfacing the kind word + dash-pattern key so sighted
  /// users hovering an edge see what VoiceOver hears AND can decode the
  /// stroke style without a legend lookup. Shape is
  /// `<source-to-target> (<kind>, <dash-key>)`. The dash key is passed in
  /// from `PolicyCanvasEdgeKind.dashDescription` at the call site so the tooltip,
  /// the legend swatch label, and the legend row's a11y label all draw
  /// from the same vocabulary. Without that single source, the previous
  /// release shipped three different words for the same stroke pattern.
  private var hoverHelpString: String {
    "\(accessibilityLabel) (\(accessibilityKindWord), \(accessibilityDashDescription))"
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
            dash: PolicyCanvasEdgeAnimation.scaledDashPattern(
              kindDashPattern,
              canvasZoom: canvasZoom
            )
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
  /// on-screen velocity. The function is constant at
  /// `baseVelocityPointsPerSecond` while the unclamped apparent velocity
  /// `baseVelocityPointsPerSecond * canvasZoom` stays under the
  /// `maxApparentVelocityPointsPerSecond` cap - that holds for every zoom
  /// `<= 2.0` because base is 12pt/sec and the cap is 24pt/sec. Above
  /// zoom 2, the apparent velocity is clamped to 24pt/sec and the
  /// returned in-route velocity scales *down* as zoom climbs so the
  /// on-screen march stays at the cap. Below zoom 1 the function is also
  /// constant at base: apparent velocity falls below 12pt/sec linearly,
  /// which is the intended slow-down at far zoom (no vestibular cost).
  /// The low `0.01` clamp keeps the division well-defined at extreme
  /// far-zoom.
  static func effectiveVelocity(canvasZoom: CGFloat) -> CGFloat {
    let zoom = max(0.01, canvasZoom)
    let apparent = min(baseVelocityPointsPerSecond * zoom, maxApparentVelocityPointsPerSecond)
    return apparent / zoom
  }

  /// Adapt a static kind-dash pattern (`[3,2]` for error, `[6,4]` for
  /// control) for far-zoom rendering. The canvas applies
  /// `.scaleEffect(viewModel.zoom)` over the whole edge layer, so a
  /// `[3,2]` world pattern renders as `~0.75pt` dashes at zoom 0.25 -
  /// approaching the device-pixel limit where dashes alias to solid.
  /// Multiplying the pattern by `1 / max(0.5, zoom)` keeps the on-screen
  /// dash period constant across zoom levels at and below 1x.
  /// (Norman R2 deferred item: dash visibility at far zoom.)
  ///
  /// At zoom >= 1 we leave the pattern alone - the existing world pattern
  /// already renders at or above its design size. Empty patterns pass
  /// through unchanged so the solid `.flow` stroke never gains a phantom
  /// dash entry.
  static func scaledDashPattern(_ pattern: [CGFloat], canvasZoom: CGFloat) -> [CGFloat] {
    guard !pattern.isEmpty, canvasZoom < 1 else {
      return pattern
    }
    let scale = 1 / max(0.5, canvasZoom)
    return pattern.map { $0 * scale }
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
