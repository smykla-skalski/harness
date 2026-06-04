import Foundation
import SwiftUI

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
  canvasPoint: CGPoint,
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
  let scaledContentSize = policyCanvasRenderedContentSize(
    viewportSize: context.viewportSize,
    contentSize: context.contentSize,
    zoom: zoom
  )
  return viewModel.viewportScrollPoint(
    keepingCanvasPoint: canvasPoint,
    atViewportPoint: context.cursor,
    viewportSize: context.viewportSize,
    scaledCanvasOffset: scaledCanvasOffset,
    contentSize: scaledContentSize,
    zoomOverride: zoom
  )
}
