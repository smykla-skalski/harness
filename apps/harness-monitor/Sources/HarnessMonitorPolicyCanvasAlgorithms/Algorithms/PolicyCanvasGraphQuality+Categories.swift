/// The single enumeration of graph-quality counters. The deterministic dump, the
/// regression gates, and the lab metrics panel all derive their numbers from this
/// list so a category is named, ordered, and counted one way everywhere.
public enum PolicyCanvasQualityCategory: CaseIterable, Sendable {
  case portOverlaps
  case portTooClose
  case portDetached
  case corridorReuse
  case corridorParallel
  case crossings
  case crossingsIndependent
  case bodyHits
  case longEdges
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
      .longEdges, .labelAdrift:
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
    case .labelOverlaps: labels.filter { $0.kind == .overlap }.count
    case .labelOnBody: labels.filter { $0.kind == .onBody }.count
    case .labelAdrift: labels.filter { $0.kind == .farFromEdge }.count
    case .nodeOverlaps: nodeOverlaps.count
    }
  }
}
