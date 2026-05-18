import Foundation
import SwiftUI

@MainActor
func policyCanvasVisibleBounds(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  labelPositions: [String: CGPoint],
  labelMetrics: PolicyCanvasEdgeLabelMetrics
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
    let frame = labelMetrics.frame(for: edge.label, center: position)
    bounds = bounds.isNull ? frame : bounds.union(frame)
  }
  guard !bounds.isNull else {
    return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
  }
  return bounds
}

func policyCanvasViewportPresentedBounds(visibleBounds: CGRect) -> CGRect {
  guard !visibleBounds.isNull else {
    return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
  }
  if visibleBounds.origin == .zero,
    visibleBounds.size == PolicyCanvasLayout.minimumCanvasSize
  {
    return visibleBounds
  }
  let targetCanvasWidth = max(
    PolicyCanvasLayout.minimumCanvasSize.width,
    visibleBounds.width + (PolicyCanvasLayout.canvasTrailingPadding * 2)
  )
  let targetCanvasHeight = max(
    PolicyCanvasLayout.minimumCanvasSize.height,
    visibleBounds.height + (PolicyCanvasLayout.canvasBottomPadding * 2)
  )
  let centeredMinX = max(
    PolicyCanvasLayout.initialContentOrigin.x,
    (targetCanvasWidth - visibleBounds.width) / 2
  )
  let centeredMinY = max(
    PolicyCanvasLayout.initialContentOrigin.y,
    (targetCanvasHeight - visibleBounds.height) / 2
  )
  return CGRect(
    x: centeredMinX,
    y: centeredMinY,
    width: visibleBounds.width,
    height: visibleBounds.height
  )
}

func policyCanvasViewportPresentationOffset(visibleBounds: CGRect) -> CGPoint {
  let presentedBounds = policyCanvasViewportPresentedBounds(visibleBounds: visibleBounds)
  return CGPoint(
    x: presentedBounds.minX - visibleBounds.minX,
    y: presentedBounds.minY - visibleBounds.minY
  )
}

func policyCanvasVisibleContentSize(visibleBounds: CGRect) -> CGSize {
  let presentedBounds = policyCanvasViewportPresentedBounds(visibleBounds: visibleBounds)
  let size = CGSize(
    width: max(
      PolicyCanvasLayout.minimumCanvasSize.width,
      presentedBounds.maxX + PolicyCanvasLayout.canvasTrailingPadding
    ),
    height: max(
      PolicyCanvasLayout.minimumCanvasSize.height,
      presentedBounds.maxY + PolicyCanvasLayout.canvasBottomPadding
    )
  )
  return size
}

func policyCanvasCanCenterViewport(
  isCanvasEmpty: Bool,
  routeOutputSignature: PolicyCanvasRouteWorkerOutputSignature
) -> Bool {
  isCanvasEmpty || routeOutputSignature != .empty
}

func policyCanvasViewportContentOrigin(
  viewportSize: CGSize,
  contentSize: CGSize,
  zoom: CGFloat
) -> CGPoint {
  let scaledWidth = contentSize.width * zoom
  let scaledHeight = contentSize.height * zoom
  return CGPoint(
    x: max((viewportSize.width - scaledWidth) / 2, 0),
    y: max((viewportSize.height - scaledHeight) / 2, 0)
  )
}

func policyCanvasRenderedContentSize(
  viewportSize: CGSize,
  contentSize: CGSize,
  zoom: CGFloat
) -> CGSize {
  CGSize(
    width: max(viewportSize.width, contentSize.width * zoom),
    height: max(viewportSize.height, contentSize.height * zoom)
  )
}

func policyCanvasCenteredScrollPoint(
  anchorPoint: CGPoint,
  viewportSize: CGSize
) -> CGPoint {
  CGPoint(
    x: max(anchorPoint.x - (viewportSize.width / 2), 0),
    y: max(anchorPoint.y - (viewportSize.height / 2), 0)
  )
}

func policyCanvasInitialViewportAnchorPoint(
  visibleBounds: CGRect,
  zoom: CGFloat
) -> CGPoint {
  let presentedBounds = policyCanvasViewportPresentedBounds(visibleBounds: visibleBounds)
  let anchorPoint = CGPoint(
    x: presentedBounds.midX * zoom,
    y: presentedBounds.midY * zoom
  )
  return anchorPoint
}

func policyCanvasCanvasPoint(
  presentedPoint: CGPoint,
  zoom: CGFloat,
  scaledCanvasOffset: CGPoint = .zero
) -> CGPoint {
  CGPoint(
    x: (presentedPoint.x - scaledCanvasOffset.x) / zoom,
    y: (presentedPoint.y - scaledCanvasOffset.y) / zoom
  )
}

struct PolicyCanvasCommandScrollContext {
  let deltaY: CGFloat
  let cursor: CGPoint
  let preZoomScrollOffset: CGPoint
  let viewportSize: CGSize
  let contentSize: CGSize
  let presentationOffset: CGPoint
}

func policyCanvasCommandScrollCanvasPoint(
  context: PolicyCanvasCommandScrollContext,
  zoom: CGFloat
) -> CGPoint {
  let contentOrigin = policyCanvasViewportContentOrigin(
    viewportSize: context.viewportSize,
    contentSize: context.contentSize,
    zoom: zoom
  )
  let scaledCanvasOffset = CGPoint(
    x: (context.presentationOffset.x * zoom) + contentOrigin.x,
    y: (context.presentationOffset.y * zoom) + contentOrigin.y
  )
  return policyCanvasCanvasPoint(
    presentedPoint: CGPoint(
      x: context.preZoomScrollOffset.x + context.cursor.x,
      y: context.preZoomScrollOffset.y + context.cursor.y
    ),
    zoom: zoom,
    scaledCanvasOffset: scaledCanvasOffset
  )
}

@MainActor
func policyCanvasCommandScrollPoint(
  viewModel: PolicyCanvasViewModel,
  context: PolicyCanvasCommandScrollContext,
  canvasPoint: CGPoint
) -> CGPoint {
  let contentOrigin = policyCanvasViewportContentOrigin(
    viewportSize: context.viewportSize,
    contentSize: context.contentSize,
    zoom: viewModel.zoom
  )
  let scaledCanvasOffset = CGPoint(
    x: (context.presentationOffset.x * viewModel.zoom) + contentOrigin.x,
    y: (context.presentationOffset.y * viewModel.zoom) + contentOrigin.y
  )
  let scaledContentSize = policyCanvasRenderedContentSize(
    viewportSize: context.viewportSize,
    contentSize: context.contentSize,
    zoom: viewModel.zoom
  )
  return viewModel.viewportScrollPoint(
    keepingCanvasPoint: canvasPoint,
    atViewportPoint: context.cursor,
    viewportSize: context.viewportSize,
    scaledCanvasOffset: scaledCanvasOffset,
    contentSize: scaledContentSize
  )
}
