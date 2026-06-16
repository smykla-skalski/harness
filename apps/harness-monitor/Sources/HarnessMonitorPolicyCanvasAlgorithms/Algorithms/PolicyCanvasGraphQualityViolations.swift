import CoreGraphics

/// Severity of a graph-quality violation. `error` marks a defect that should
/// never ship (overlapping port markers, an edge crossing a node body);
/// `warning` marks a readability cleanup (a corridor shared a little too
/// tightly, a label that drifted off its wire).
public enum PolicyCanvasQualitySeverity: String, Equatable, Sendable {
  case warning
  case error
}

/// A port marker (route attach point) spaced wrong on a node side. The
/// route-terminal marker placement draws each port dot exactly where its wire
/// attaches, so measuring the attach points groups the visible dots per node
/// side and flags overlaps, sub-minimum gaps, and dots that float off the node.
public struct PolicyCanvasPortSpacingViolation: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    /// Two markers closer than the port diameter - they visibly overlap.
    case overlap
    /// Closer than the minimum spacing but not yet overlapping.
    case tooClose
    /// A marker that does not sit on any edge of its node frame.
    case detached
    /// A marker sitting far from the canonical evenly-spread slot for its
    /// position on the side - dots clustered or crammed rather than distributed.
    case uneven
  }

  public let kind: Kind
  public let nodeID: String
  public let side: PolicyCanvasPortSide
  public let point: CGPoint
  public let otherPoint: CGPoint?
  public let gap: CGFloat
  public let edgeIDs: [String]

  public init(
    kind: Kind,
    nodeID: String,
    side: PolicyCanvasPortSide,
    point: CGPoint,
    otherPoint: CGPoint?,
    gap: CGFloat,
    edgeIDs: [String]
  ) {
    self.kind = kind
    self.nodeID = nodeID
    self.side = side
    self.point = point
    self.otherPoint = otherPoint
    self.gap = gap
    self.edgeIDs = edgeIDs
  }

  public var severity: PolicyCanvasQualitySeverity {
    switch kind {
    case .overlap, .detached: .error
    case .tooClose, .uneven: .warning
    }
  }
}

/// Two route interior segments sharing a corridor. `collinear` means both run
/// in the same lane and overlap along it (one wire stacked on another);
/// `parallelTooClose` means they run parallel within the minimum separation.
public struct PolicyCanvasCorridorViolation: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case collinear
    case parallelTooClose
  }

  public let kind: Kind
  public let isHorizontal: Bool
  public let edgeA: String
  public let edgeB: String
  public let overlapStart: CGPoint
  public let overlapEnd: CGPoint
  public let separation: CGFloat

  public init(
    kind: Kind,
    isHorizontal: Bool,
    edgeA: String,
    edgeB: String,
    overlapStart: CGPoint,
    overlapEnd: CGPoint,
    separation: CGFloat
  ) {
    self.kind = kind
    self.isHorizontal = isHorizontal
    self.edgeA = edgeA
    self.edgeB = edgeB
    self.overlapStart = overlapStart
    self.overlapEnd = overlapEnd
    self.separation = separation
  }

  public var severity: PolicyCanvasQualitySeverity {
    kind == .collinear ? .error : .warning
  }
}

/// Two routes that cross at a proper interior orthogonal X. `sharesEndpointNode`
/// flags crossings between edges that touch the same node, which are sometimes
/// unavoidable, so a gate can budget those separately from independent crossings.
public struct PolicyCanvasCrossingViolation: Equatable, Sendable {
  public let edgeA: String
  public let edgeB: String
  public let point: CGPoint
  public let sharesEndpointNode: Bool

  public init(edgeA: String, edgeB: String, point: CGPoint, sharesEndpointNode: Bool) {
    self.edgeA = edgeA
    self.edgeB = edgeB
    self.point = point
    self.sharesEndpointNode = sharesEndpointNode
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}

/// A route that runs through a node body or group-title band that is not one of
/// its own endpoints.
public struct PolicyCanvasBodyHitViolation: Equatable, Sendable {
  public enum Obstacle: String, Equatable, Sendable {
    case node
    case groupTitle
  }

  public let edgeID: String
  public let obstacle: Obstacle
  public let obstacleID: String
  public let frame: CGRect

  public init(edgeID: String, obstacle: Obstacle, obstacleID: String, frame: CGRect) {
    self.edgeID = edgeID
    self.obstacle = obstacle
    self.obstacleID = obstacleID
    self.frame = frame
  }

  public var severity: PolicyCanvasQualitySeverity { .error }
}

/// A route long enough to read as a cross-canvas hauler. `horizontalSpan` is the
/// dominant signal for the braid case (an edge dragged across most of the width).
public struct PolicyCanvasLongEdgeViolation: Equatable, Sendable {
  public let edgeID: String
  public let length: CGFloat
  public let horizontalSpan: CGFloat
  public let verticalSpan: CGFloat
  public let bendCount: Int
  public let bounds: CGRect

  public init(
    edgeID: String,
    length: CGFloat,
    horizontalSpan: CGFloat,
    verticalSpan: CGFloat,
    bendCount: Int,
    bounds: CGRect
  ) {
    self.edgeID = edgeID
    self.length = length
    self.horizontalSpan = horizontalSpan
    self.verticalSpan = verticalSpan
    self.bendCount = bendCount
    self.bounds = bounds
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}

/// A label that collides with another label, sits on a foreign node body,
/// drifted far from its own wire, lies on top of a foreign wire, or crowds a
/// route bend.
public struct PolicyCanvasLabelViolation: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case overlap
    case onBody
    case farFromEdge
    /// The label box sits on top of a wire other than the one it names.
    case crossesEdge
    /// The label box overlaps or sits too close to a route bend (its own or a
    /// neighbor's), crowding the corner.
    case nearTurn
  }

  public let kind: Kind
  public let edgeID: String
  public let otherID: String?
  public let frame: CGRect
  public let distance: CGFloat

  public init(kind: Kind, edgeID: String, otherID: String?, frame: CGRect, distance: CGFloat) {
    self.kind = kind
    self.edgeID = edgeID
    self.otherID = otherID
    self.frame = frame
    self.distance = distance
  }

  public var severity: PolicyCanvasQualitySeverity {
    switch kind {
    case .overlap, .onBody: .error
    case .farFromEdge, .crossesEdge, .nearTurn: .warning
    }
  }
}

/// Two node bodies whose frames intersect.
public struct PolicyCanvasNodeOverlapViolation: Equatable, Sendable {
  public let nodeA: String
  public let nodeB: String
  public let intersection: CGRect

  public init(nodeA: String, nodeB: String, intersection: CGRect) {
    self.nodeA = nodeA
    self.nodeB = nodeB
    self.intersection = intersection
  }

  public var severity: PolicyCanvasQualitySeverity { .error }
}

/// A route that travels much farther than the straight Manhattan distance
/// between its endpoints - it loops or backtracks instead of heading toward its
/// target. `excess` is the wasted travel (route length minus the ideal); a
/// monotone L- or Z-shaped route has zero excess.
public struct PolicyCanvasDetourViolation: Equatable, Sendable {
  public let edgeID: String
  public let length: CGFloat
  public let idealLength: CGFloat
  public let excess: CGFloat
  public let points: [CGPoint]
  public let bounds: CGRect

  public init(
    edgeID: String,
    length: CGFloat,
    idealLength: CGFloat,
    excess: CGFloat,
    points: [CGPoint],
    bounds: CGRect
  ) {
    self.edgeID = edgeID
    self.length = length
    self.idealLength = idealLength
    self.excess = excess
    self.points = points
    self.bounds = bounds
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}

/// A route that doubles back on itself: it travels along one axis, then reverses
/// and travels the opposite way along that same axis. The reversing segment is
/// the visible spur - a wire that leaves a port the wrong way and hooks back, or
/// wraps around to reach a port on the far side. `depth` is how far it backtracks
/// (the length of the reversing segment); `point` is where the wire turns back
/// and `returnPoint` is the far end of the spur.
public struct PolicyCanvasWrongTurnViolation: Equatable, Sendable {
  public let edgeID: String
  public let point: CGPoint
  public let returnPoint: CGPoint
  public let depth: CGFloat

  public init(edgeID: String, point: CGPoint, returnPoint: CGPoint, depth: CGFloat) {
    self.edgeID = edgeID
    self.point = point
    self.returnPoint = returnPoint
    self.depth = depth
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}

/// Two wires that attach to one node side in an order that crosses them: the
/// wire reaching the earlier port along the side comes from farther along the
/// perpendicular axis than the wire reaching the later port, so the two must
/// cross between the node and where they come from. Swapping the two ports would
/// untangle them - the edge picked the wrong port. `pointA` is the earlier port
/// (smaller offset along the side), `pointB` the later one.
public struct PolicyCanvasCrossedPortsViolation: Equatable, Sendable {
  public let nodeID: String
  public let side: PolicyCanvasPortSide
  public let edgeA: String
  public let edgeB: String
  public let pointA: CGPoint
  public let pointB: CGPoint

  public init(
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgeA: String,
    edgeB: String,
    pointA: CGPoint,
    pointB: CGPoint
  ) {
    self.nodeID = nodeID
    self.side = side
    self.edgeA = edgeA
    self.edgeB = edgeB
    self.pointA = pointA
    self.pointB = pointB
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}

/// Two connected node bodies separated by a wide horizontal gap - the layout
/// placed them far apart with empty space between, forcing a long hauling edge.
/// `distance` is the gap between their facing vertical edges.
public struct PolicyCanvasNodeDistanceViolation: Equatable, Sendable {
  public let edgeID: String
  public let sourceID: String
  public let targetID: String
  public let distance: CGFloat
  public let gapStart: CGPoint
  public let gapEnd: CGPoint

  public init(
    edgeID: String,
    sourceID: String,
    targetID: String,
    distance: CGFloat,
    gapStart: CGPoint,
    gapEnd: CGPoint
  ) {
    self.edgeID = edgeID
    self.sourceID = sourceID
    self.targetID = targetID
    self.distance = distance
    self.gapStart = gapStart
    self.gapEnd = gapEnd
  }

  public var severity: PolicyCanvasQualitySeverity { .warning }
}
