import Foundation
import HarnessMonitorPolicyCanvasAlgorithms
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
  routeOutputSignature: PolicyCanvasRouteWorkerOutputSignature,
  currentRouteKey: PolicyCanvasRouteWorkerKey,
  appliedRouteKey: PolicyCanvasRouteWorkerKey?
) -> Bool {
  appliedRouteKey == currentRouteKey && (isCanvasEmpty || routeOutputSignature != .empty)
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

func policyCanvasInitialViewportScrollPoint(
  visibleBounds: CGRect,
  viewportSize: CGSize,
  zoom: CGFloat,
  contentOrigin: CGPoint = .zero
) -> CGPoint {
  let anchorPoint = policyCanvasInitialViewportAnchorPoint(
    visibleBounds: visibleBounds,
    zoom: zoom
  )
  let centeredPoint = policyCanvasCenteredScrollPoint(
    anchorPoint: CGPoint(
      x: anchorPoint.x + contentOrigin.x,
      y: anchorPoint.y + contentOrigin.y
    ),
    viewportSize: viewportSize
  )
  return centeredPoint
}

func policyCanvasInitialViewportAnchorPoint(
  visibleBounds: CGRect,
  zoom: CGFloat
) -> CGPoint {
  let presentedBounds = policyCanvasViewportPresentedBounds(visibleBounds: visibleBounds)
  let anchorPoint = CGPoint(
    x: presentedBounds.midX * zoom,
    y: (presentedBounds.midY + PolicyCanvasLayout.initialViewportTopBias) * zoom
  )
  return anchorPoint
}

func policyCanvasDocumentCenteredScrollPoint(
  anchorPoint: CGPoint,
  viewportSize: CGSize,
  zoom: CGFloat
) -> CGPoint {
  let resolvedZoom = max(zoom, 0.001)
  return CGPoint(
    x: anchorPoint.x - (viewportSize.width / (resolvedZoom * 2)),
    y: anchorPoint.y - (viewportSize.height / (resolvedZoom * 2))
  )
}

func policyCanvasInitialViewportDocumentScrollPoint(
  visibleBounds: CGRect,
  viewportSize: CGSize,
  zoom: CGFloat
) -> CGPoint {
  let anchorPoint = policyCanvasInitialViewportDocumentAnchorPoint(visibleBounds: visibleBounds)
  return policyCanvasDocumentCenteredScrollPoint(
    anchorPoint: anchorPoint,
    viewportSize: viewportSize,
    zoom: zoom
  )
}

func policyCanvasInitialViewportDocumentAnchorPoint(
  visibleBounds: CGRect
) -> CGPoint {
  guard !visibleBounds.isNull else {
    return CGPoint(
      x: PolicyCanvasLayout.minimumCanvasSize.width / 2,
      y: PolicyCanvasLayout.minimumCanvasSize.height / 2
    )
  }
  return CGPoint(x: visibleBounds.midX, y: visibleBounds.midY)
}

@MainActor
func policyCanvasViewportCenteringSelectionScrollPoint(
  behavior: PolicyCanvasViewportCenteringBehavior,
  selection: PolicyCanvasSelection?,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput = .empty,
  viewportSize: CGSize,
  zoom: CGFloat
) -> CGPoint? {
  guard behavior == .selectionIfPresent else {
    return nil
  }
  return selection.flatMap { selection in
    policyCanvasSelectionViewportDocumentScrollPoint(
      selection: selection,
      viewModel: viewModel,
      routeOutput: routeOutput,
      viewportSize: viewportSize,
      zoom: zoom
    )
  }
}

@MainActor
func policyCanvasViewportCenteringSelectionDocumentAnchorPoint(
  behavior: PolicyCanvasViewportCenteringBehavior,
  selection: PolicyCanvasSelection?,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput = .empty
) -> CGPoint? {
  guard behavior == .selectionIfPresent else {
    return nil
  }
  return selection.flatMap { selection in
    policyCanvasSelectionViewportDocumentAnchorPoint(
      selection: selection,
      viewModel: viewModel,
      routeOutput: routeOutput
    )
  }
}

@MainActor
func policyCanvasSelectionViewportScrollPoint(
  selection: PolicyCanvasSelection,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput,
  viewportSize: CGSize,
  zoom: CGFloat,
  contentOrigin: CGPoint = .zero
) -> CGPoint? {
  let anchorPoint: CGPoint?
  switch selection {
  case .node(let nodeID):
    guard let node = viewModel.node(nodeID) else {
      return nil
    }
    let frame = viewModel.nodeFrame(for: node)
    anchorPoint = CGPoint(
      x: (frame.midX * zoom) + contentOrigin.x,
      y: (frame.midY * zoom) + contentOrigin.y
    )
  case .group(let groupID):
    guard let group = viewModel.group(groupID) else {
      return nil
    }
    anchorPoint = CGPoint(
      x: (group.frame.midX * zoom) + contentOrigin.x,
      y: (group.frame.midY * zoom) + contentOrigin.y
    )
  case .edge(let edgeID):
    guard
      let labelPosition = routeOutput.labelPositions[edgeID]
        ?? routeOutput.routes[edgeID]?.labelPosition
    else {
      return nil
    }
    anchorPoint = CGPoint(
      x: (labelPosition.x * zoom) + contentOrigin.x,
      y: (labelPosition.y * zoom) + contentOrigin.y
    )
  }

  guard let anchorPoint else {
    return nil
  }
  return policyCanvasCenteredScrollPoint(
    anchorPoint: anchorPoint,
    viewportSize: viewportSize
  )
}

@MainActor
func policyCanvasSelectionViewportDocumentScrollPoint(
  selection: PolicyCanvasSelection,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput,
  viewportSize: CGSize,
  zoom: CGFloat
) -> CGPoint? {
  guard
    let anchorPoint = policyCanvasSelectionViewportDocumentAnchorPoint(
      selection: selection,
      viewModel: viewModel,
      routeOutput: routeOutput
    )
  else {
    return nil
  }
  return policyCanvasDocumentCenteredScrollPoint(
    anchorPoint: anchorPoint,
    viewportSize: viewportSize,
    zoom: zoom
  )
}

@MainActor
func policyCanvasSelectionViewportDocumentAnchorPoint(
  selection: PolicyCanvasSelection,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput
) -> CGPoint? {
  let anchorPoint: CGPoint?
  switch selection {
  case .node(let nodeID):
    guard let node = viewModel.node(nodeID) else {
      return nil
    }
    let frame = viewModel.nodeFrame(for: node)
    anchorPoint = CGPoint(x: frame.midX, y: frame.midY)
  case .group(let groupID):
    guard let group = viewModel.group(groupID) else {
      return nil
    }
    anchorPoint = CGPoint(x: group.frame.midX, y: group.frame.midY)
  case .edge(let edgeID):
    guard
      let labelPosition = routeOutput.labelPositions[edgeID]
        ?? routeOutput.routes[edgeID]?.labelPosition
    else {
      return nil
    }
    anchorPoint = labelPosition
  }

  guard let anchorPoint else {
    return nil
  }
  return anchorPoint
}
