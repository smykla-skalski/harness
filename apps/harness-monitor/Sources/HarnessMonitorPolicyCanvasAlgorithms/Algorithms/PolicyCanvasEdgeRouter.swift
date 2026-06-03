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
public struct PolicyCanvasRouteContext: Hashable, Sendable {
  public let lane: Int
  public let groups: [PolicyCanvasGroup]
  public let sourceGroupID: String?
  public let targetGroupID: String?
  public let obstacles: [CGRect]
  public let sourceActual: CGPoint?
  public let targetActual: CGPoint?
  public let lineSpacing: CGFloat
  public let corridorHint: PolicyCanvasEdgeCorridorHint?

  public init(
    lane: Int,
    groups: [PolicyCanvasGroup],
    sourceGroupID: String?,
    targetGroupID: String?,
    obstacles: [CGRect] = [],
    obstaclesAreCanonical: Bool = false,
    sourceActual: CGPoint? = nil,
    targetActual: CGPoint? = nil,
    lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing,
    corridorHint: PolicyCanvasEdgeCorridorHint? = nil
  ) {
    self.lane = lane
    self.groups = groups
    self.sourceGroupID = sourceGroupID
    self.targetGroupID = targetGroupID
    // Canonicalize obstacle order so two callers passing the same logical
    // obstacles in different orders share a cache entry. Array Hashable
    // would otherwise treat [A, B] and [B, A] as different keys and force
    // a redundant A* recomputation.
    self.obstacles =
      obstaclesAreCanonical ? obstacles : policyCanvasCanonicalObstacles(obstacles)
    self.sourceActual = sourceActual
    self.targetActual = targetActual
    self.lineSpacing = lineSpacing
    self.corridorHint = corridorHint
  }
}

public func policyCanvasCanonicalObstacles(_ obstacles: [CGRect]) -> [CGRect] {
  obstacles.sorted { lhs, rhs in
    if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
    if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
    if lhs.width != rhs.width { return lhs.width < rhs.width }
    return lhs.height < rhs.height
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
/// supplies a real ranking.
public protocol PolicyCanvasEdgeRouter: Sendable {
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

public extension PolicyCanvasEdgeRouter {
  /// Default flex-anchor implementation for routers that don't supply their
  /// own cost-aware override. Returns the route for the first candidate pair
  /// - no real ranking happens here. `PolicyCanvasVisibilityRouter` provides
  /// the real override that ranks emitted-route cost for selection.
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
public struct PolicyCanvasHandCodedOrthogonalRouter: PolicyCanvasEdgeRouter {
  public func route(
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
  /// include the full input so cross-canvas collisions are not possible.
  /// Capacity is 1024 entries with LRU eviction in
  /// `PolicyCanvasMemoizedRouter`.
  /// Tests that want raw routing characteristics can still inject a bare
  /// `PolicyCanvasVisibilityRouter()` via `.environment(...)`.
  static let defaultValue: any PolicyCanvasEdgeRouter =
    PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
}

public extension EnvironmentValues {
  var policyCanvasEdgeRouter: any PolicyCanvasEdgeRouter {
    get { self[PolicyCanvasEdgeRouterKey.self] }
    set { self[PolicyCanvasEdgeRouterKey.self] = newValue }
  }
}

public typealias PolicyCanvasRouteAnchorCandidate = (point: CGPoint, side: PolicyCanvasPortSide)

public func policyCanvasDefaultEdgeRouter() -> any PolicyCanvasEdgeRouter {
  PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
}

func policyCanvasSignedLaneOffset(index: Int, spacing: CGFloat) -> CGFloat {
  guard index > 0 else {
    return 0
  }
  let magnitude = CGFloat((index + 1) / 2) * spacing
  return index.isMultiple(of: 2) ? -magnitude : magnitude
}
