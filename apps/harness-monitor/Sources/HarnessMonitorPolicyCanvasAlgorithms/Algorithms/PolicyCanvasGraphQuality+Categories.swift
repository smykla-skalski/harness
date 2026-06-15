/// The single enumeration of graph-quality counters. The deterministic dump, the
/// regression gates, and the lab metrics panel all derive their numbers from this
/// list so a category is named, ordered, and counted one way everywhere.
public enum PolicyCanvasQualityCategory: CaseIterable, Equatable, Hashable, Sendable {
  case portOverlaps
  case portTooClose
  case portDetached
  case corridorReuse
  case corridorParallel
  case crossings
  case crossingsIndependent
  case bodyHits
  case longEdges
  case detours
  case nodeDistance
  case wrongTurns
  case crossedPorts
  case labelOverlaps
  case labelOnBody
  case labelAdrift
  case nodeOverlaps

  /// Human-readable counter name, also used as the dump/panel row label.
  public var label: String {
    switch self {
    case .portOverlaps: "port overlaps"
    case .portTooClose: "port too-close"
    case .portDetached: "port detached"
    case .corridorReuse: "corridor reuse"
    case .corridorParallel: "corridor parallel"
    case .crossings: "crossings"
    case .crossingsIndependent: "crossings independent"
    case .bodyHits: "body hits"
    case .longEdges: "long edges"
    case .detours: "detours"
    case .nodeDistance: "node distance"
    case .wrongTurns: "wrong turns"
    case .crossedPorts: "crossed ports"
    case .labelOverlaps: "label overlaps"
    case .labelOnBody: "label on-body"
    case .labelAdrift: "label adrift"
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
    case .portTooClose, .corridorParallel, .crossings, .crossingsIndependent,
      .longEdges, .detours, .nodeDistance, .wrongTurns, .crossedPorts, .labelAdrift:
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
    case .nodeOverlaps:
      "Two node bodies overlap"
    }
  }
}

extension PolicyCanvasGraphQualityReport {
  /// Count of violations in a single category.
  public func count(for category: PolicyCanvasQualityCategory) -> Int {
    switch category {
    case .portOverlaps: portSpacing.filter { $0.kind == .overlap }.count
    case .portTooClose: portSpacing.filter { $0.kind == .tooClose }.count
    case .portDetached: portSpacing.filter { $0.kind == .detached }.count
    case .corridorReuse: corridors.filter { $0.kind == .collinear }.count
    case .corridorParallel: corridors.filter { $0.kind == .parallelTooClose }.count
    case .crossings: crossings.count
    case .crossingsIndependent: crossings.filter { !$0.sharesEndpointNode }.count
    case .bodyHits: bodyHits.count
    case .longEdges: longEdges.count
    case .detours: detours.count
    case .nodeDistance: nodeDistance.count
    case .wrongTurns: wrongTurns.count
    case .crossedPorts: crossedPorts.count
    case .labelOverlaps: labels.filter { $0.kind == .overlap }.count
    case .labelOnBody: labels.filter { $0.kind == .onBody }.count
    case .labelAdrift: labels.filter { $0.kind == .farFromEdge }.count
    case .nodeOverlaps: nodeOverlaps.count
    }
  }
}
