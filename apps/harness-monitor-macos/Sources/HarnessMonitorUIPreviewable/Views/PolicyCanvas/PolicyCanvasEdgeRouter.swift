import SwiftUI

/// Pluggable edge-routing strategy. The current implementation is the
/// six-case hand-coded orthogonal router (`PolicyCanvasHandCodedOrthogonalRouter`);
/// future implementations include a channel-model unification and a
/// visibility-graph A* router. Consumers read the router from the
/// `\.policyCanvasEdgeRouter` environment value and invoke `route(...)`
/// per-edge rather than constructing `PolicyCanvasEdgeRoute` directly.
protocol PolicyCanvasEdgeRouter: Sendable {
  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?
  ) -> PolicyCanvasEdgeRoute
}

/// Default router. Delegates to the existing `PolicyCanvasEdgeRoute` init
/// (six hand-coded cases) so the protocol introduction is bit-identical to
/// pre-refactor output. Tests in `PolicyCanvasEdgeRoutingTests` confirm the
/// polyline pins survive.
struct PolicyCanvasHandCodedOrthogonalRouter: PolicyCanvasEdgeRouter {
  func route(
    source: CGPoint,
    target: CGPoint,
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?
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
    PolicyCanvasHandCodedOrthogonalRouter()
}

extension EnvironmentValues {
  var policyCanvasEdgeRouter: any PolicyCanvasEdgeRouter {
    get { self[PolicyCanvasEdgeRouterKey.self] }
    set { self[PolicyCanvasEdgeRouterKey.self] = newValue }
  }
}
