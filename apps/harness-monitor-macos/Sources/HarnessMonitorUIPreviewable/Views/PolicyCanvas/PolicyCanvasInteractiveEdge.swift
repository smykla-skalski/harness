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
  let onTap: () -> Void
  let onDelete: () -> Void

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
      PolicyCanvasEdgeShape(route: route)
        .stroke(
          color,
          style: StrokeStyle(
            lineWidth: isSelected ? strokeWidth + 1.0 : strokeWidth,
            lineCap: .round,
            lineJoin: .round
          )
        )
      PolicyCanvasEdgeArrowhead(route: route)
        .fill(color)
    }
    .contentShape(PolicyCanvasEdgeHitShape(route: route))
    .onTapGesture(perform: onTap)
    .contextMenu {
      Button("Delete edge", role: .destructive, action: onDelete)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
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
