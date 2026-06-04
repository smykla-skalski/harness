import CoreGraphics

/// One edge's membership in a fan, derived once from the routed endpoints.
///
/// A fan-in is the set of edges that converge on one shared target anchor; a
/// fan-out is the set that diverge from one shared source anchor. Members are
/// ranked by the position of their *other* endpoint (the source for a fan-in,
/// the target for a fan-out) projected onto the axis along which the fan
/// spreads. Both the horizontal corridor a fan funnels through and the vertical
/// column it turns into are then ordered by this one shared rank, so the two
/// channels agree at their shared corner and the spread adds no crossing.
struct PolicyCanvasFanMembership {
  let groupKey: PolicyCanvasFanContext.PointKey
  let convergence: CGPoint
  let rank: Int
}

struct PolicyCanvasFanContext {
  /// A routed endpoint rounded to whole points - two edges share a port when
  /// their stubs land on the same anchor, and floating noise must not split a
  /// real fan into singletons.
  struct PointKey: Hashable {
    let x: Int
    let y: Int

    init(_ point: CGPoint) {
      x = Int(point.x.rounded())
      y = Int(point.y.rounded())
    }
  }

  let fanInByEdge: [String: PolicyCanvasFanMembership]
  let fanOutByEdge: [String: PolicyCanvasFanMembership]

  static func make(from routes: [String: [CGPoint]]) -> PolicyCanvasFanContext {
    typealias Member = (edge: String, convergence: CGPoint, other: CGPoint)
    var byTarget: [PointKey: [Member]] = [:]
    var bySource: [PointKey: [Member]] = [:]
    for (edge, points) in routes {
      guard points.count >= 2, let first = points.first, let last = points.last else {
        continue
      }
      byTarget[PointKey(last), default: []].append((edge, last, first))
      bySource[PointKey(first), default: []].append((edge, first, last))
    }
    return PolicyCanvasFanContext(
      fanInByEdge: memberships(from: byTarget),
      fanOutByEdge: memberships(from: bySource)
    )
  }

  private static func memberships(
    from groups: [PointKey: [(edge: String, convergence: CGPoint, other: CGPoint)]]
  ) -> [String: PolicyCanvasFanMembership] {
    var result: [String: PolicyCanvasFanMembership] = [:]
    for (key, members) in groups where members.count > 1 {
      let xValues = members.map { $0.other.x }
      let yValues = members.map { $0.other.y }
      let spreadX = (xValues.max() ?? 0) - (xValues.min() ?? 0)
      let spreadY = (yValues.max() ?? 0) - (yValues.min() ?? 0)
      let spreadsHorizontally = spreadX >= spreadY
      let ordered = members.sorted { left, right in
        let leftPrimary = spreadsHorizontally ? left.other.x : left.other.y
        let rightPrimary = spreadsHorizontally ? right.other.x : right.other.y
        if leftPrimary != rightPrimary {
          return leftPrimary < rightPrimary
        }
        let leftSecondary = spreadsHorizontally ? left.other.y : left.other.x
        let rightSecondary = spreadsHorizontally ? right.other.y : right.other.x
        if leftSecondary != rightSecondary {
          return leftSecondary < rightSecondary
        }
        return left.edge < right.edge
      }
      for (rank, member) in ordered.enumerated() {
        result[member.edge] = PolicyCanvasFanMembership(
          groupKey: key,
          convergence: member.convergence,
          rank: rank
        )
      }
    }
    return result
  }
}
