import SwiftUI

/// Routing input the canvas hands to a `PolicyCanvasEdgeRouter`.
///
/// **Cache identity invariant.** `PolicyCanvasMemoizedRouter` uses this
/// struct's synthesized `Hashable` derivation as the cache key for the
/// non-endpoint portion of every routing call. Every field that any
/// concrete router reads MUST be a stored property here, and the
/// `Hashable` synthesis MUST cover it. Adding a non-routing field
/// (telemetry handle, debug flag, anything the routing function does
/// not actually consume) silently widens the cache key and burns hit
/// rate; adding a *routing*-relevant input without adding it here
/// silently serves stale polylines.
///
/// The contract test in
/// `Tests/HarnessMonitorKitTests/PolicyCanvasMemoizedRouterContextContractTests.swift`
/// guards the second failure mode by mutating each field one at a time
/// and asserting the wrapped router miss-rate flips to 100%. New fields
/// must extend that test in the same change.
struct PolicyCanvasRouteContext: Hashable, Sendable {
  let lane: Int
  let groups: [PolicyCanvasGroup]
  let sourceGroupID: String?
  let targetGroupID: String?
  let obstacles: [CGRect]
  let sourceActual: CGPoint?
  let targetActual: CGPoint?
  let lineSpacing: CGFloat

  init(
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect] = [],
    sourceActual: CGPoint? = nil,
    targetActual: CGPoint? = nil,
    lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
  ) {
    self.lane = lane
    self.groups = groups
    self.sourceGroupID = sourceGroupID
    self.targetGroupID = targetGroupID
    self.obstacles = obstacles
    self.sourceActual = sourceActual
    self.targetActual = targetActual
    self.lineSpacing = lineSpacing
  }
}

/// Pluggable edge-routing strategy. Two implementations ship today:
/// `PolicyCanvasHandCodedOrthogonalRouter` (six-case hand-coded) and
/// `PolicyCanvasVisibilityRouter` (sparse orthogonal visibility graph + A*,
/// active default on production canvases). Consumers read the router from the
/// `\.policyCanvasEdgeRouter` environment value and invoke `route(...)`
/// per-edge rather than constructing `PolicyCanvasEdgeRoute` directly.
///
/// Rollback path: to switch the canvas back to the hand-coded router for
/// debugging or as a feature-flag fallback, inject it via the environment
/// at the canvas root: `.environment(\.policyCanvasEdgeRouter,
/// PolicyCanvasHandCodedOrthogonalRouter())`. The hand-coded router stays
/// available as both a top-level conformance and as the internal fallback
/// the visibility router falls back to when A* cannot find a path.
///
/// `route(sourceCandidates:targetCandidates:...)` is a protocol requirement
/// rather than an extension method so concrete routers can override it with
/// cost-aware selection. The default implementation (in the extension
/// below) is single-anchor pick-the-first; only `PolicyCanvasVisibilityRouter`
/// supplies a real ranking by consuming A*'s gScore directly. There is no
/// second cost function in the codebase: A*'s interior cost is the single
/// source of truth, and a fallback combo (no A* solution) is skipped during
/// flex ranking rather than scored.
protocol PolicyCanvasEdgeRouter: Sendable {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute

  /// Flex-anchor routing for T2.2. Concrete routers override to rank
  /// candidates by their internal cost. The extension default short-circuits
  /// to the first candidate so non-flex-aware routers (the hand-coded
  /// fallback) remain valid conformances. See the type-level doc above for
  /// the ranking discipline.
  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute
}

extension PolicyCanvasEdgeRouter {
  /// Default flex-anchor implementation for routers that don't supply their
  /// own cost-aware override. Returns the route for the first candidate pair
  /// - no real ranking happens here. `PolicyCanvasVisibilityRouter` provides
  /// the real override that consumes A*'s gScore for selection.
  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    route(
      source: sourceCandidates.first ?? .zero,
      target: targetCandidates.first ?? .zero,
      context: context
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
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(
      source: source,
      target: target,
      lane: context.lane,
      groups: context.groups,
      sourceGroupID: context.sourceGroupID,
      targetGroupID: context.targetGroupID
    )
  }
}

private struct PolicyCanvasEdgeRouterKey: EnvironmentKey {
  /// Default to a memoized visibility router. SwiftUI body re-evaluation
  /// on selection / hover / `TimelineView(.animation)` tick used to
  /// dispatch N route calls per invocation; with this default, repeat
  /// routes for unchanged geometry resolve from the cache instead of
  /// re-running A*. The cache lives for the process lifetime - keys
  /// include the full input so cross-canvas collisions are not possible,
  /// and a wipe-on-overflow cap (1024 entries) bounds RAM (drops the
  /// whole cache on overflow rather than running an LRU eviction list).
  /// Tests that want raw routing characteristics can still inject a bare
  /// `PolicyCanvasVisibilityRouter()` via `.environment(...)`.
  static let defaultValue: any PolicyCanvasEdgeRouter =
    PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
}

extension EnvironmentValues {
  var policyCanvasEdgeRouter: any PolicyCanvasEdgeRouter {
    get { self[PolicyCanvasEdgeRouterKey.self] }
    set { self[PolicyCanvasEdgeRouterKey.self] = newValue }
  }
}

typealias PolicyCanvasRouteAnchorCandidate = (point: CGPoint, side: PolicyCanvasPortSide)

struct PolicyCanvasPinnedDisplayedRouteRequest {
  let router: any PolicyCanvasEdgeRouter
  let source: PolicyCanvasRouteAnchorCandidate
  let sourceFanoutLane: Int
  let target: PolicyCanvasRouteAnchorCandidate
  let targetFanoutLane: Int
  let context: PolicyCanvasRouteContext
}

struct PolicyCanvasFlexibleDisplayedRouteRequest {
  let router: any PolicyCanvasEdgeRouter
  let sourceCandidates: [PolicyCanvasRouteAnchorCandidate]
  let sourceFanoutLane: Int
  let targetCandidates: [PolicyCanvasRouteAnchorCandidate]
  let targetFanoutLane: Int
  let context: PolicyCanvasRouteContext
}

func policyCanvasPortLeadDistance(lane: Int) -> CGFloat {
  policyCanvasPortLeadDistance(lane: lane, lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing)
}

func policyCanvasPortLeadDistance(lane: Int, lineSpacing: CGFloat) -> CGFloat {
  PolicyCanvasLayout.edgePortTurnMinimumLead
    + (CGFloat(max(0, lane)) * lineSpacing)
}

func policyCanvasSignedLaneOffset(index: Int, spacing: CGFloat) -> CGFloat {
  guard index > 0 else {
    return 0
  }
  let magnitude = CGFloat((index + 1) / 2) * spacing
  return index.isMultiple(of: 2) ? -magnitude : magnitude
}

func policyCanvasMonotonicLaneOffset(index: Int, spacing: CGFloat) -> CGFloat {
  guard index > 0 else {
    return 0
  }
  return CGFloat(index) * spacing
}

func policyCanvasPortLaneOffset(
  index: Int,
  side: PolicyCanvasPortSide,
  spacing: CGFloat
) -> CGFloat {
  switch side {
  case .leading, .trailing:
    policyCanvasMonotonicLaneOffset(index: index, spacing: spacing)
  case .top, .bottom:
    policyCanvasSignedLaneOffset(index: index, spacing: spacing)
  }
}

func policyCanvasPortEscapeCandidate(
  from point: CGPoint,
  side: PolicyCanvasPortSide,
  lane: Int,
  lineSpacing: CGFloat
) -> PolicyCanvasEscapeCandidate {
  let distance = policyCanvasPortLeadDistance(lane: lane, lineSpacing: lineSpacing)
  let offset = policyCanvasPortLaneOffset(
    index: lane,
    side: side,
    spacing: lineSpacing
  )
  switch side {
  case .leading:
    let exit = CGPoint(x: point.x - distance, y: point.y)
    return PolicyCanvasEscapeCandidate(
      side: side,
      actual: point,
      exit: exit,
      routed: CGPoint(x: exit.x, y: exit.y + offset)
    )
  case .trailing:
    let exit = CGPoint(x: point.x + distance, y: point.y)
    return PolicyCanvasEscapeCandidate(
      side: side,
      actual: point,
      exit: exit,
      routed: CGPoint(x: exit.x, y: exit.y + offset)
    )
  case .top:
    let exit = CGPoint(x: point.x, y: point.y - distance)
    return PolicyCanvasEscapeCandidate(
      side: side,
      actual: point,
      exit: exit,
      routed: CGPoint(x: exit.x + offset, y: exit.y)
    )
  case .bottom:
    let exit = CGPoint(x: point.x, y: point.y + distance)
    return PolicyCanvasEscapeCandidate(
      side: side,
      actual: point,
      exit: exit,
      routed: CGPoint(x: exit.x + offset, y: exit.y)
    )
  }
}

func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasPinnedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let source = request.source.point
  let target = request.target.point
  let sourceCandidate = policyCanvasPortEscapeCandidate(
    from: source,
    side: request.source.side,
    lane: request.sourceFanoutLane,
    lineSpacing: request.context.lineSpacing
  )
  let targetCandidate = policyCanvasPortEscapeCandidate(
    from: target,
    side: request.target.side,
    lane: request.targetFanoutLane,
    lineSpacing: request.context.lineSpacing
  )
  let routingContext = PolicyCanvasRouteContext(
    lane: request.context.lane,
    groups: request.context.groups,
    sourceGroupID: request.context.sourceGroupID,
    targetGroupID: request.context.targetGroupID,
    obstacles: request.context.obstacles,
    sourceActual: request.context.sourceActual ?? source,
    targetActual: request.context.targetActual ?? target,
    lineSpacing: request.context.lineSpacing
  )
  let baseRoute = request.router.route(
    source: sourceCandidate.routed,
    target: targetCandidate.routed,
    context: routingContext
  )
  return policyCanvasBridgedRoute(
    baseRoute: baseRoute,
    source: sourceCandidate,
    target: targetCandidate
  )
}

func policyCanvasDisplayedRoute(
  _ request: PolicyCanvasFlexibleDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let sourceCandidates = request.sourceCandidates
  let targetCandidates = request.targetCandidates
  guard !sourceCandidates.isEmpty, !targetCandidates.isEmpty else {
    return PolicyCanvasEdgeRoute(points: [], labelPosition: .zero)
  }
  let routedSources = sourceCandidates.map {
    policyCanvasPortEscapeCandidate(
      from: $0.point,
      side: $0.side,
      lane: request.sourceFanoutLane,
      lineSpacing: request.context.lineSpacing
    )
  }
  let routedTargets = targetCandidates.map {
    policyCanvasPortEscapeCandidate(
      from: $0.point,
      side: $0.side,
      lane: request.targetFanoutLane,
      lineSpacing: request.context.lineSpacing
    )
  }
  let routingContext = PolicyCanvasRouteContext(
    lane: request.context.lane,
    groups: request.context.groups,
    sourceGroupID: request.context.sourceGroupID,
    targetGroupID: request.context.targetGroupID,
    obstacles: request.context.obstacles,
    sourceActual: request.context.sourceActual ?? sourceCandidates.first?.point,
    targetActual: request.context.targetActual ?? targetCandidates.first?.point,
    lineSpacing: request.context.lineSpacing
  )
  var bestRoute: PolicyCanvasEdgeRoute?
  var bestScore: CGFloat = .infinity
  for source in routedSources {
    for target in routedTargets {
      let baseRoute = request.router.route(
        source: source.routed,
        target: target.routed,
        context: routingContext
      )
      let displayedRoute = policyCanvasBridgedRoute(
        baseRoute: baseRoute,
        source: source,
        target: target
      )
      let score = policyCanvasDisplayedRouteScore(
        displayedRoute,
        source: source,
        target: target
      )
      if score < bestScore {
        bestScore = score
        bestRoute = displayedRoute
      }
    }
  }
  return bestRoute
    ?? policyCanvasBridgedRoute(
      baseRoute: request.router.route(
        source: routedSources[0].routed,
        target: routedTargets[0].routed,
        context: routingContext
      ),
      source: routedSources[0],
      target: routedTargets[0]
    )
}
