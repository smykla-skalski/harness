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
