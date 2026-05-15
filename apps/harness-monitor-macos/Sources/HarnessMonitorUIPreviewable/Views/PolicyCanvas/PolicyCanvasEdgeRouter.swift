import SwiftUI

/// Pluggable edge-routing strategy. Two implementations ship today:
/// `PolicyCanvasHandCodedOrthogonalRouter` (six-case hand-coded) and
/// `PolicyCanvasVisibilityRouter` (sparse orthogonal visibility graph + A*,
/// active default on production canvases). Consumers read the router from the
/// `\.policyCanvasEdgeRouter` environment value and invoke `route(...)`
/// per-edge rather than constructing `PolicyCanvasEdgeRoute` directly.
protocol PolicyCanvasEdgeRouter: Sendable {
  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect]
  ) -> PolicyCanvasEdgeRoute
}

extension PolicyCanvasEdgeRouter {
  /// Convenience overload for call sites that don't have per-node frames yet
  /// (older tests, hand-coded route comparisons). Forwards with an empty
  /// obstacle list so the hand-coded router stays bit-identical.
  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?
  ) -> PolicyCanvasEdgeRoute {
    route(
      source: source,
      target: target,
      lane: lane,
      groups: groups,
      sourceGroupID: sourceGroupID,
      targetGroupID: targetGroupID,
      obstacles: []
    )
  }

  /// Flex-anchor routing for T2.2. Tries every combination of source/target
  /// candidates and returns the route with the lowest length+bend cost. The
  /// caller decides which endpoints are flexed; pinned endpoints supply a
  /// single-element list. Empty candidate lists short-circuit to the legacy
  /// single-anchor `route(source:target:...)` overload with the fallback
  /// `firstCandidate ?? .zero`.
  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect]
  ) -> PolicyCanvasEdgeRoute {
    guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
      return route(
        source: sourceCandidates.first ?? .zero,
        target: targetCandidates.first ?? .zero,
        lane: lane,
        groups: groups,
        sourceGroupID: sourceGroupID,
        targetGroupID: targetGroupID,
        obstacles: obstacles
      )
    }
    var bestRoute: PolicyCanvasEdgeRoute?
    var bestCost: CGFloat = .infinity
    for sourceAnchor in sourceCandidates {
      for targetAnchor in targetCandidates {
        let candidate = route(
          source: sourceAnchor,
          target: targetAnchor,
          lane: lane,
          groups: groups,
          sourceGroupID: sourceGroupID,
          targetGroupID: targetGroupID,
          obstacles: obstacles
        )
        let cost = PolicyCanvasRouteCost.compute(candidate.points)
        if cost < bestCost {
          bestCost = cost
          bestRoute = candidate
        }
      }
    }
    return bestRoute
      ?? route(
        source: sourceCandidates[0],
        target: targetCandidates[0],
        lane: lane,
        groups: groups,
        sourceGroupID: sourceGroupID,
        targetGroupID: targetGroupID,
        obstacles: obstacles
      )
  }
}

/// Cost helper for flex-anchor selection. Mirrors the router's interior
/// scoring (length + bend penalty) so the candidate-selection loop ranks
/// routes the same way A* does internally.
enum PolicyCanvasRouteCost {
  static func compute(_ points: [CGPoint]) -> CGFloat {
    guard points.count >= 2 else {
      return .infinity
    }
    var length: CGFloat = 0
    var bends = 0
    for index in 0..<points.count - 1 {
      length +=
        abs(points[index + 1].x - points[index].x)
        + abs(points[index + 1].y - points[index].y)
      if index >= 1 {
        let prev = points[index - 1]
        let cur = points[index]
        let next = points[index + 1]
        let prevHorizontal = abs(cur.y - prev.y) < 0.0001
        let nextHorizontal = abs(next.y - cur.y) < 0.0001
        if prevHorizontal != nextHorizontal {
          bends += 1
        }
      }
    }
    return length + CGFloat(bends) * PolicyCanvasVisibilityRouter.bendPenalty
  }
}

/// Legacy router preserving the six hand-coded orthogonal cases. Kept as a
/// fallback for tests that pin specific polyline outputs and as the engine
/// `PolicyCanvasVisibilityRouter` falls back to when A* cannot find a path
/// through its sparse grid. Obstacles are accepted but ignored - the
/// hand-coded cases use group frames only.
struct PolicyCanvasHandCodedOrthogonalRouter: PolicyCanvasEdgeRouter {
  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect]
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(
      source: source,
      target: target,
      lane: lane,
      groups: groups,
      sourceGroupID: sourceGroupID,
      targetGroupID: targetGroupID
    )
  }
}

private struct PolicyCanvasEdgeRouterKey: EnvironmentKey {
  static let defaultValue: any PolicyCanvasEdgeRouter =
    PolicyCanvasVisibilityRouter()
}

extension EnvironmentValues {
  var policyCanvasEdgeRouter: any PolicyCanvasEdgeRouter {
    get { self[PolicyCanvasEdgeRouterKey.self] }
    set { self[PolicyCanvasEdgeRouterKey.self] = newValue }
  }
}
