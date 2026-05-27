import SwiftUI

typealias PolicyCanvasPortVisibilityMap = [PolicyCanvasPortEndpoint: Set<PolicyCanvasPortSide>]

@MainActor
func policyCanvasPortVisibility(
  viewModel: PolicyCanvasViewModel,
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute]
) -> PolicyCanvasPortVisibilityMap {
  policyCanvasPortVisibility(
    edges: edges,
    routes: routes,
    anchorCandidates: { viewModel.portAnchorCandidates(for: $0) }
  )
}

func policyCanvasPortVisibility(
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  anchorCandidates: (PolicyCanvasPortEndpoint) -> [PolicyCanvasRouteAnchorCandidate]
) -> PolicyCanvasPortVisibilityMap {
  var visibility: PolicyCanvasPortVisibilityMap = [:]
  for edge in edges {
    guard let route = routes[edge.id] else {
      continue
    }
    if let side = policyCanvasMatchedSourcePortSide(
      route: route,
      candidates: anchorCandidates(edge.source)
    ) {
      policyCanvasInsertVisibleSide(side, for: edge.source, into: &visibility)
    }
    if let side = policyCanvasMatchedTargetPortSide(
      route: route,
      candidates: anchorCandidates(edge.target)
    ) {
      policyCanvasInsertVisibleSide(side, for: edge.target, into: &visibility)
    }
  }
  return visibility
}

func policyCanvasVisiblePortSides(
  for endpoint: PolicyCanvasPortEndpoint,
  visibility: PolicyCanvasPortVisibilityMap,
  nodeIsActive: Bool = false,
  hasPendingEdge: Bool = false
) -> Set<PolicyCanvasPortSide> {
  if let visibleSides = visibility[policyCanvasCanonicalPortEndpoint(endpoint)],
    !visibleSides.isEmpty
  {
    return visibleSides
  }
  guard nodeIsActive || hasPendingEdge else {
    return []
  }
  return [endpoint.side ?? policyCanvasDefaultPortSide(for: endpoint.kind)]
}

func policyCanvasRouteSourceSide(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide? {
  guard route.points.count >= 2 else {
    return nil
  }
  return policyCanvasRouteSide(from: route.points[0], to: route.points[1])
}

func policyCanvasRouteTargetSide(_ route: PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide? {
  guard route.points.count >= 2,
    let previous = route.points.dropLast().last,
    let target = route.points.last
  else {
    return nil
  }
  return policyCanvasRouteSide(from: target, to: previous)
}

private func policyCanvasMatchedSourcePortSide(
  route: PolicyCanvasEdgeRoute,
  candidates: [PolicyCanvasRouteAnchorCandidate]
) -> PolicyCanvasPortSide? {
  guard let sourcePoint = route.points.first else {
    return nil
  }
  return policyCanvasMatchedPortSide(point: sourcePoint, candidates: candidates)
    ?? policyCanvasRouteSourceSide(route)
}

private func policyCanvasMatchedTargetPortSide(
  route: PolicyCanvasEdgeRoute,
  candidates: [PolicyCanvasRouteAnchorCandidate]
) -> PolicyCanvasPortSide? {
  guard let targetPoint = route.points.last else {
    return nil
  }
  return policyCanvasMatchedPortSide(point: targetPoint, candidates: candidates)
    ?? policyCanvasRouteTargetSide(route)
}

private func policyCanvasMatchedPortSide(
  point: CGPoint,
  candidates: [PolicyCanvasRouteAnchorCandidate]
) -> PolicyCanvasPortSide? {
  candidates.first { candidate in
    abs(candidate.point.x - point.x) < 0.001 && abs(candidate.point.y - point.y) < 0.001
  }?.side
}

private func policyCanvasRouteSide(from point: CGPoint, to adjacent: CGPoint)
  -> PolicyCanvasPortSide?
{
  if adjacent.x > point.x + 0.001 {
    return .trailing
  }
  if adjacent.x < point.x - 0.001 {
    return .leading
  }
  if adjacent.y > point.y + 0.001 {
    return .bottom
  }
  if adjacent.y < point.y - 0.001 {
    return .top
  }
  return nil
}

private func policyCanvasInsertVisibleSide(
  _ side: PolicyCanvasPortSide,
  for endpoint: PolicyCanvasPortEndpoint,
  into visibility: inout PolicyCanvasPortVisibilityMap
) {
  let key = policyCanvasCanonicalPortEndpoint(endpoint)
  visibility[key, default: []].insert(side)
}

private func policyCanvasDefaultPortSide(for kind: PolicyCanvasPortKind) -> PolicyCanvasPortSide {
  kind == .input ? .leading : .trailing
}
