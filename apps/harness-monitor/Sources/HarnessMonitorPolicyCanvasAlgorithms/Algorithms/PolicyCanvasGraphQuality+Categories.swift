/// The single enumeration of graph-quality counters. The deterministic dump, the
/// regression gates, and the lab metrics panel all derive their numbers from this
/// list so a category is named, ordered, and counted one way everywhere.
public enum PolicyCanvasQualityCategory: CaseIterable, Equatable, Hashable, Sendable {
  case portOverlaps
  case portTooClose
  case portDetached
  case portUneven
  case corridorReuse
  case corridorParallel
  case crossings
  case crossingsIndependent
  case bodyHits
  case longEdges
  case detours
  case routeSegments
  case nodeDistance
  case wrongTurns
  case crossedPorts
  case labelOverlaps
  case labelOnBody
  case labelAdrift
  case labelOnEdge
  case labelNearTurn
  case nodeOverlaps

  /// Human-readable counter name, also used as the dump/panel row label.
  public var label: String {
    switch self {
    case .portOverlaps: "port overlaps"
    case .portTooClose: "port too-close"
    case .portDetached: "port detached"
    case .portUneven: "port uneven"
    case .corridorReuse: "corridor reuse"
    case .corridorParallel: "corridor parallel"
    case .crossings: "crossings"
    case .crossingsIndependent: "crossings independent"
    case .bodyHits: "body hits"
    case .longEdges: "long edges"
    case .detours: "detours"
    case .routeSegments: "edge segments"
    case .nodeDistance: "node distance"
    case .wrongTurns: "wrong turns"
    case .crossedPorts: "crossed ports"
    case .labelOverlaps: "label overlaps"
    case .labelOnBody: "label on-body"
    case .labelAdrift: "label adrift"
    case .labelOnEdge: "label on-edge"
    case .labelNearTurn: "label near-turn"
    case .nodeOverlaps: "node overlaps"
    }
  }

  /// Severity used to color the counter and to decide whether a non-zero value is
  /// an error or a warning in the panel.
  public var severity: PolicyCanvasQualitySeverity {
    switch self {
    case .portOverlaps, .portDetached, .corridorReuse, .bodyHits,
      .labelOverlaps, .labelOnBody, .nodeOverlaps:
      .error
    case .portTooClose, .portUneven, .corridorParallel, .crossings, .crossingsIndependent,
      .longEdges, .detours, .routeSegments, .nodeDistance, .wrongTurns, .crossedPorts,
      .labelAdrift, .labelOnEdge, .labelNearTurn:
      .warning
    }
  }

  /// Whether the regression gate enforces a per-sample budget on this counter.
  /// Raw `crossings` is shown for context but not gated; `crossingsIndependent`
  /// (crossings between edges that share no endpoint node) carries the real
  /// crossing signal, so it is the gated one.
  public var isGated: Bool {
    self != .crossings
  }

  /// Plain-language description of the defect, shown in the lab metrics legend so
  /// a marker on the canvas can be decoded without reading the source.
  public var detail: String {
    switch self {
    case .portOverlaps:
      "Two port markers on one node side overlap - their dots sit on top of each other"
    case .portTooClose:
      "Two port markers on one side are closer than the minimum spacing - the dots crowd"
    case .portDetached:
      "A wire ends away from its port dot - the edge does not reach the marker it should attach to"
    case .portUneven:
      "A port dot sits far from where an even spread would place it - dots clustered or "
        + "crammed, not evenly distributed on the side"
    case .corridorReuse:
      "Two wires share one lane and overlap along it - they stack on the same rail"
    case .corridorParallel:
      "Two wires run parallel closer than the minimum lane separation"
    case .crossings:
      "Any two wires crossing at a right angle - shown for context, not gated"
    case .crossingsIndependent:
      "Wires that share no endpoint node yet still cross - the avoidable crossings"
    case .bodyHits:
      "A wire runs through a node body or group-title band that is not its own endpoint"
    case .longEdges:
      "A wire spans most of the canvas width - a cross-canvas hauler"
    case .detours:
      "A wire travels much farther than the straight path between its ports - it loops or backtracks"
    case .routeSegments:
      "A straight wire segment is shorter than one grid step or not an integer multiple of the grid"
    case .nodeDistance:
      "Two connected nodes sit far apart horizontally with a wide empty gap between them"
    case .wrongTurns:
      "A wire doubles back on itself - it heads one way then reverses along the same axis, leaving a spur"
    case .crossedPorts:
      "Two wires attach to one node side in a crossed order - swapping the ports would untangle them"
    case .labelOverlaps:
      "Two edge labels overlap each other"
    case .labelOnBody:
      "An edge label sits on top of a node body"
    case .labelAdrift:
      "An edge label drifted far from the wire it names"
    case .labelOnEdge:
      "An edge label sits on top of a wire other than the one it names"
    case .labelNearTurn:
      "An edge label overlaps or sits too close to a wire's turn - it crowds the corner"
    case .nodeOverlaps:
      "Two node bodies overlap"
    }
  }
}

extension PolicyCanvasGraphQualityReport {
  /// Count of violations in a single category. Split across three grouped
  /// helpers so no single switch trips the cyclomatic-complexity gate: each
  /// helper owns a disjoint slice of the categories and returns nil for the
  /// rest, so exactly one helper answers any category.
  public func count(for category: PolicyCanvasQualityCategory) -> Int {
    portCorridorCrossingCount(for: category)
      ?? edgeRouteViolationCount(for: category)
      ?? labelNodeViolationCount(for: category)
      ?? 0
  }

  /// Port-spacing, corridor, and raw/independent crossing counters.
  private func portCorridorCrossingCount(for category: PolicyCanvasQualityCategory) -> Int? {
    switch category {
    case .portOverlaps: portSpacing.filter { $0.kind == .overlap }.count
    case .portTooClose: portSpacing.filter { $0.kind == .tooClose }.count
    case .portDetached: portSpacing.filter { $0.kind == .detached }.count
    case .portUneven: portSpacing.filter { $0.kind == .uneven }.count
    case .corridorReuse: corridors.filter { $0.kind == .collinear }.count
    case .corridorParallel: corridors.filter { $0.kind == .parallelTooClose }.count
    case .crossings: crossings.count
    case .crossingsIndependent: crossings.filter { !$0.sharesEndpointNode }.count
    default: nil
    }
  }

  /// Edge- and route-geometry counters (body hits, long edges, detours,
  /// segments, node distance, wrong turns, crossed ports).
  private func edgeRouteViolationCount(for category: PolicyCanvasQualityCategory) -> Int? {
    switch category {
    case .bodyHits: bodyHits.count
    case .longEdges: longEdges.count
    case .detours: detours.count
    case .routeSegments: routeSegments.count
    case .nodeDistance: nodeDistance.count
    case .wrongTurns: wrongTurns.count
    case .crossedPorts: crossedPorts.count
    default: nil
    }
  }

  /// Label-placement and node-overlap counters.
  private func labelNodeViolationCount(for category: PolicyCanvasQualityCategory) -> Int? {
    switch category {
    case .labelOverlaps: labels.filter { $0.kind == .overlap }.count
    case .labelOnBody: labels.filter { $0.kind == .onBody }.count
    case .labelAdrift: labels.filter { $0.kind == .farFromEdge }.count
    case .labelOnEdge: labels.filter { $0.kind == .crossesEdge }.count
    case .labelNearTurn: labels.filter { $0.kind == .nearTurn }.count
    case .nodeOverlaps: nodeOverlaps.count
    default: nil
    }
  }
}
