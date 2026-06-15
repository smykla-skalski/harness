import CoreGraphics

/// Tunable thresholds for the graph-quality measurement. Defaults derive from
/// the same layout constants the router and port placement use, so the report
/// flags exactly what those passes were trying to avoid. A gate can tighten or
/// relax any field without touching the measurement logic.
public struct PolicyCanvasGraphQualityThresholds: Equatable, Sendable {
  /// Minimum gap between two distinct port markers on one node side.
  public var minimumPortSpacing: CGFloat
  /// Gap below which two markers count as overlapping rather than merely tight.
  public var markerOverlap: CGFloat
  /// Collinear overlap length that reads as one wire stacked on another.
  public var corridorOverlap: CGFloat
  /// Parallel separation below which two same-axis corridors crowd each other.
  public var minimumCorridorSeparation: CGFloat
  /// Horizontal span past which a route counts as a cross-canvas long edge.
  public var longEdgeSpan: CGFloat
  /// Distance from a label to its own wire past which the label reads as adrift.
  public var labelFarDistance: CGFloat
  /// Excess route travel (length past the straight Manhattan distance) above
  /// which a route reads as an unnecessary detour.
  public var detourExcess: CGFloat
  /// Horizontal gap between two connected node bodies above which they read as
  /// placed too far apart.
  public var nodeDistanceGap: CGFloat
  /// Minimum length of a reversing route segment for the backtrack to read as a
  /// wrong turn. Shorter reversals sit within a port marker and are ignored.
  public var wrongTurnDepth: CGFloat
  /// Distance between a wire end and its rendered port dot past which the wire
  /// reads as detached from its port. Below a full port diameter the wire end
  /// still meets the dot.
  public var portDetachDistance: CGFloat

  public init(
    minimumPortSpacing: CGFloat,
    markerOverlap: CGFloat,
    corridorOverlap: CGFloat,
    minimumCorridorSeparation: CGFloat,
    longEdgeSpan: CGFloat,
    labelFarDistance: CGFloat,
    detourExcess: CGFloat,
    nodeDistanceGap: CGFloat,
    wrongTurnDepth: CGFloat,
    portDetachDistance: CGFloat
  ) {
    self.minimumPortSpacing = minimumPortSpacing
    self.markerOverlap = markerOverlap
    self.corridorOverlap = corridorOverlap
    self.minimumCorridorSeparation = minimumCorridorSeparation
    self.longEdgeSpan = longEdgeSpan
    self.labelFarDistance = labelFarDistance
    self.detourExcess = detourExcess
    self.nodeDistanceGap = nodeDistanceGap
    self.wrongTurnDepth = wrongTurnDepth
    self.portDetachDistance = portDetachDistance
  }

  public static let `default` = Self(
    minimumPortSpacing: policyCanvasMinimumPortMarkerSpacing(),
    markerOverlap: PolicyCanvasLayout.portDiameter,
    corridorOverlap: 8,
    minimumCorridorSeparation: PolicyCanvasLayout.defaultEdgeLineSpacing,
    longEdgeSpan: PolicyCanvasLayout.nodeSize.width * 3,
    labelFarDistance: 60,
    detourExcess: PolicyCanvasLayout.nodeSize.height * 1.5,
    nodeDistanceGap: PolicyCanvasLayout.nodeSize.width * 2.5,
    // Two-thirds of a port marker: shorter backtracks sit within the dot.
    wrongTurnDepth: PolicyCanvasLayout.portDiameter / 1.5,
    // A full port diameter: the wire end is a dot-width clear of the dot.
    portDetachDistance: PolicyCanvasLayout.portDiameter
  )
}

/// Aggregate edge-length figures over every routed edge.
public struct PolicyCanvasEdgeLengthSummary: Equatable, Sendable {
  public let routedEdgeCount: Int
  public let totalLength: CGFloat
  public let averageLength: CGFloat
  public let maxLength: CGFloat
  public let totalBends: Int
  public let maxBends: Int

  public init(
    routedEdgeCount: Int,
    totalLength: CGFloat,
    averageLength: CGFloat,
    maxLength: CGFloat,
    totalBends: Int,
    maxBends: Int
  ) {
    self.routedEdgeCount = routedEdgeCount
    self.totalLength = totalLength
    self.averageLength = averageLength
    self.maxLength = maxLength
    self.totalBends = totalBends
    self.maxBends = maxBends
  }

  public static let empty = Self(
    routedEdgeCount: 0,
    totalLength: 0,
    averageLength: 0,
    maxLength: 0,
    totalBends: 0,
    maxBends: 0
  )
}

/// Overall canvas extent and how densely the nodes fill it.
public struct PolicyCanvasBoundsSummary: Equatable, Sendable {
  public let contentBounds: CGRect
  public let nodeOccupancyRatio: CGFloat
  public let aspectRatio: CGFloat

  public init(contentBounds: CGRect, nodeOccupancyRatio: CGFloat, aspectRatio: CGFloat) {
    self.contentBounds = contentBounds
    self.nodeOccupancyRatio = nodeOccupancyRatio
    self.aspectRatio = aspectRatio
  }

  public static let empty = Self(
    contentBounds: .zero,
    nodeOccupancyRatio: 0,
    aspectRatio: 0
  )
}

/// Deterministic, route-based quality report for one laid-out graph. Holds the
/// per-violation detail (geometry + ids) the overlay and dump need, plus the
/// scalar summaries a gate ratchets against. Every array is sorted by a stable
/// key so the report is reproducible and `Equatable` across runs.
public struct PolicyCanvasGraphQualityReport: Equatable, Sendable {
  public var portSpacing: [PolicyCanvasPortSpacingViolation]
  public var corridors: [PolicyCanvasCorridorViolation]
  public var crossings: [PolicyCanvasCrossingViolation]
  public var bodyHits: [PolicyCanvasBodyHitViolation]
  public var longEdges: [PolicyCanvasLongEdgeViolation]
  public var detours: [PolicyCanvasDetourViolation]
  public var nodeDistance: [PolicyCanvasNodeDistanceViolation]
  public var wrongTurns: [PolicyCanvasWrongTurnViolation]
  public var crossedPorts: [PolicyCanvasCrossedPortsViolation]
  public var labels: [PolicyCanvasLabelViolation]
  public var nodeOverlaps: [PolicyCanvasNodeOverlapViolation]
  public var edgeLengths: PolicyCanvasEdgeLengthSummary
  public var bounds: PolicyCanvasBoundsSummary

  public init(
    portSpacing: [PolicyCanvasPortSpacingViolation],
    corridors: [PolicyCanvasCorridorViolation],
    crossings: [PolicyCanvasCrossingViolation],
    bodyHits: [PolicyCanvasBodyHitViolation],
    longEdges: [PolicyCanvasLongEdgeViolation],
    detours: [PolicyCanvasDetourViolation],
    nodeDistance: [PolicyCanvasNodeDistanceViolation],
    wrongTurns: [PolicyCanvasWrongTurnViolation],
    crossedPorts: [PolicyCanvasCrossedPortsViolation],
    labels: [PolicyCanvasLabelViolation],
    nodeOverlaps: [PolicyCanvasNodeOverlapViolation],
    edgeLengths: PolicyCanvasEdgeLengthSummary,
    bounds: PolicyCanvasBoundsSummary
  ) {
    self.portSpacing = portSpacing
    self.corridors = corridors
    self.crossings = crossings
    self.bodyHits = bodyHits
    self.longEdges = longEdges
    self.detours = detours
    self.nodeDistance = nodeDistance
    self.wrongTurns = wrongTurns
    self.crossedPorts = crossedPorts
    self.labels = labels
    self.nodeOverlaps = nodeOverlaps
    self.edgeLengths = edgeLengths
    self.bounds = bounds
  }

  public static let empty = Self(
    portSpacing: [],
    corridors: [],
    crossings: [],
    bodyHits: [],
    longEdges: [],
    detours: [],
    nodeDistance: [],
    wrongTurns: [],
    crossedPorts: [],
    labels: [],
    nodeOverlaps: [],
    edgeLengths: .empty,
    bounds: .empty
  )

  /// Count of error-severity violations across every category.
  public var errorCount: Int {
    portSpacing.filter { $0.severity == .error }.count
      + corridors.filter { $0.severity == .error }.count
      + bodyHits.count
      + labels.filter { $0.severity == .error }.count
      + nodeOverlaps.count
  }
}

/// An edge paired with the route that was computed for it.
struct PolicyCanvasRoutedEdge {
  let edge: PolicyCanvasEdge
  let route: PolicyCanvasEdgeRoute
}

/// Measure deterministic graph-quality metrics from a laid-out, routed graph.
/// Convenience entry that derives node frames and group-title bands from the
/// model types, then delegates to the frame-based core.
///
/// Pass `portMarkerLayout` (the same layout the canvas renders its dots from) to
/// also measure wires detached from their port dot. The frame-based core cannot
/// see the marker layout, so that signal is folded in here, where the node port
/// geometry is available.
public func policyCanvasMeasureGraphQuality(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil,
  thresholds: PolicyCanvasGraphQualityThresholds = .default
) -> PolicyCanvasGraphQualityReport {
  var report = policyCanvasMeasureGraphQuality(
    nodeFramesByID: Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.id, policyCanvasNodeFrame($0)) }
    ),
    groupTitleFrames: policyCanvasGroupTitleFramesByID(groups),
    edges: edges,
    routes: routes,
    thresholds: thresholds
  )
  guard let portMarkerLayout else {
    return report
  }
  let routedEdges =
    edges
    .compactMap { edge -> PolicyCanvasRoutedEdge? in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
    .sorted { $0.edge.id < $1.edge.id }
  let detached = policyCanvasMeasurePortDetachment(
    routedEdges: routedEdges,
    nodesByID: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
    portMarkerLayout: portMarkerLayout,
    thresholds: thresholds
  )
  report.portSpacing =
    (report.portSpacing + detached).sorted(by: policyCanvasPortSpacingViolationOrder)
  return report
}

/// Frame-based core. Pure: same inputs always yield the same report. The
/// routed-edge list drops edges without a usable route up front so every
/// sub-measure sees the same set. Tests drive this overload directly with
/// hand-built frames to stay independent of the node-kind catalog.
public func policyCanvasMeasureGraphQuality(
  nodeFramesByID: [String: CGRect],
  groupTitleFrames: [(id: String, frame: CGRect)],
  edges: [PolicyCanvasEdge],
  routes: [String: PolicyCanvasEdgeRoute],
  thresholds: PolicyCanvasGraphQualityThresholds = .default
) -> PolicyCanvasGraphQualityReport {
  let routedEdges =
    edges
    .compactMap { edge -> PolicyCanvasRoutedEdge? in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
    .sorted { $0.edge.id < $1.edge.id }
  let edgeLengths = policyCanvasMeasureEdgeLengths(
    routedEdges: routedEdges,
    thresholds: thresholds
  )
  let boundsResult = policyCanvasMeasureBounds(
    nodeFramesByID: nodeFramesByID,
    routes: routes
  )
  return PolicyCanvasGraphQualityReport(
    portSpacing: policyCanvasMeasurePortSpacing(
      routedEdges: routedEdges,
      nodeFramesByID: nodeFramesByID,
      thresholds: thresholds
    ),
    corridors: policyCanvasMeasureCorridors(
      routedEdges: routedEdges,
      thresholds: thresholds
    ),
    crossings: policyCanvasMeasureCrossings(routedEdges: routedEdges),
    bodyHits: policyCanvasMeasureBodyHits(
      routedEdges: routedEdges,
      nodeFramesByID: nodeFramesByID,
      groupTitleFrames: groupTitleFrames
    ),
    longEdges: edgeLengths.longEdges,
    detours: edgeLengths.detours,
    nodeDistance: policyCanvasMeasureNodeDistance(
      edges: edges,
      nodeFramesByID: nodeFramesByID,
      thresholds: thresholds
    ),
    wrongTurns: policyCanvasMeasureWrongTurns(routedEdges: routedEdges, thresholds: thresholds),
    crossedPorts: policyCanvasMeasureCrossedPorts(
      routedEdges: routedEdges,
      nodeFramesByID: nodeFramesByID
    ),
    labels: policyCanvasMeasureLabels(
      routedEdges: routedEdges,
      nodeFramesByID: nodeFramesByID,
      thresholds: thresholds
    ),
    nodeOverlaps: boundsResult.overlaps,
    edgeLengths: edgeLengths.summary,
    bounds: boundsResult.summary
  )
}
