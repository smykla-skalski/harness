import SwiftUI

@MainActor
func policyCanvasVisibleBounds(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  labelPositions: [String: CGPoint],
  labelSize: CGSize
) -> CGRect {
  var bounds = viewModel.canvasContentBounds
  for route in routes.values {
    for point in route.points {
      let pointRect = CGRect(origin: point, size: .zero)
      bounds = bounds.isNull ? pointRect : bounds.union(pointRect)
    }
  }
  for edge in edges {
    guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
      continue
    }
    let frame = CGRect(
      x: position.x - (labelSize.width / 2),
      y: position.y - (labelSize.height / 2),
      width: labelSize.width,
      height: labelSize.height
    )
    bounds = bounds.isNull ? frame : bounds.union(frame)
  }
  guard !bounds.isNull else {
    return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
  }
  return bounds
}

func policyCanvasVisibleContentSize(visibleBounds: CGRect) -> CGSize {
  CGSize(
    width: max(
      PolicyCanvasLayout.minimumCanvasSize.width,
      visibleBounds.maxX + PolicyCanvasLayout.canvasTrailingPadding
    ),
    height: max(
      PolicyCanvasLayout.minimumCanvasSize.height,
      visibleBounds.maxY + PolicyCanvasLayout.canvasBottomPadding
    )
  )
}

func policyCanvasInitialViewportAnchorPoint(
  visibleBounds: CGRect,
  zoom: CGFloat
) -> CGPoint {
  CGPoint(
    x: visibleBounds.midX * zoom,
    y: visibleBounds.midY * zoom
  )
}
