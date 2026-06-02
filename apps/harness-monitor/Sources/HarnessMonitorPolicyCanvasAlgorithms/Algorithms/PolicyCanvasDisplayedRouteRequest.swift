import SwiftUI

public struct PolicyCanvasResolvedDisplayedRouteRequest {
  public let router: any PolicyCanvasEdgeRouter
  public let edge: PolicyCanvasEdge
  public let source: CGPoint
  public let target: CGPoint
  public let routeLane: Int
  public let sourceFanoutLane: Int
  public let targetFanoutLane: Int
  public let lineSpacing: CGFloat
  public let obstacles: [CGRect]
  public let groups: [PolicyCanvasGroup]
  public let sourceGroupID: String?
  public let targetGroupID: String?
  public let sourceAnchor: PolicyCanvasRouteAnchorCandidate
  public let targetAnchor: PolicyCanvasRouteAnchorCandidate
  public let sourceCandidates: [PolicyCanvasRouteAnchorCandidate]
  public let targetCandidates: [PolicyCanvasRouteAnchorCandidate]
  public let sourceSpacingBySide: [PolicyCanvasPortSide: CGFloat]
  public let targetSpacingBySide: [PolicyCanvasPortSide: CGFloat]
  public let corridorHint: PolicyCanvasEdgeCorridorHint?

  public init(
    router: any PolicyCanvasEdgeRouter,
    edge: PolicyCanvasEdge,
    source: CGPoint,
    target: CGPoint,
    routeLane: Int,
    sourceFanoutLane: Int,
    targetFanoutLane: Int,
    lineSpacing: CGFloat,
    obstacles: [CGRect],
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    sourceAnchor: PolicyCanvasRouteAnchorCandidate,
    targetAnchor: PolicyCanvasRouteAnchorCandidate,
    sourceCandidates: [PolicyCanvasRouteAnchorCandidate],
    targetCandidates: [PolicyCanvasRouteAnchorCandidate],
    sourceSpacingBySide: [PolicyCanvasPortSide: CGFloat],
    targetSpacingBySide: [PolicyCanvasPortSide: CGFloat],
    corridorHint: PolicyCanvasEdgeCorridorHint?
  ) {
    self.router = router
    self.edge = edge
    self.source = source
    self.target = target
    self.routeLane = routeLane
    self.sourceFanoutLane = sourceFanoutLane
    self.targetFanoutLane = targetFanoutLane
    self.lineSpacing = lineSpacing
    self.obstacles = obstacles
    self.groups = groups
    self.sourceGroupID = sourceGroupID
    self.targetGroupID = targetGroupID
    self.sourceAnchor = sourceAnchor
    self.targetAnchor = targetAnchor
    self.sourceCandidates = sourceCandidates
    self.targetCandidates = targetCandidates
    self.sourceSpacingBySide = sourceSpacingBySide
    self.targetSpacingBySide = targetSpacingBySide
    self.corridorHint = corridorHint
  }
}

public func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let context = policyCanvasRouteContext(for: request)
  if request.edge.effectivePinnedPortSide {
    return policyCanvasDisplayedRoute(
      PolicyCanvasPinnedDisplayedRouteRequest(
        router: request.router,
        source: request.sourceAnchor,
        sourceFanoutLane: request.sourceFanoutLane,
        target: request.targetAnchor,
        targetFanoutLane: request.targetFanoutLane,
        context: context
      )
    )
  }
  return policyCanvasDisplayedRoute(
    PolicyCanvasFlexibleDisplayedRouteRequest(
      router: request.router,
      sourceCandidates: request.sourceCandidates,
      sourceFanoutLane: request.sourceFanoutLane,
      targetCandidates: request.targetCandidates,
      targetFanoutLane: request.targetFanoutLane,
      context: context
    )
  )
}

public func policyCanvasRouteContext(
  for request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasRouteContext {
  PolicyCanvasRouteContext(
    lane: request.routeLane,
    groups: request.groups,
    sourceGroupID: request.sourceGroupID,
    targetGroupID: request.targetGroupID,
    obstacles: request.obstacles,
    obstaclesAreCanonical: true,
    sourceActual: request.source,
    targetActual: request.target,
    lineSpacing: request.lineSpacing,
    corridorHint: request.corridorHint
  )
}

public func policyCanvasResolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
  endpoint.side ?? (endpoint.kind == .input ? .leading : .trailing)
}
