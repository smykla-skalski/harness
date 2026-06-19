import CoreGraphics

extension PolicyCanvasVisibilityRouter {
  func simpleVisibilityRoute(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect]
  ) -> PolicyCanvasEdgeRoute? {
    let snapValidationObstacles = prepared.map {
      $0.insetBy(dx: Self.channelStep / 2, dy: Self.channelStep / 2)
    }
    let candidates = simpleVisibilityCandidatePoints(
      source: source,
      target: target,
      context: context
    )
    var best: (route: PolicyCanvasEdgeRoute, cost: CGFloat)?
    for candidate in candidates {
      let compressed = Self.compressCollinear(candidate)
      guard compressed.count >= 2 else {
        continue
      }
      let spread = Self.applyLaneSpread(
        compressed,
        lane: context.lane,
        source: source,
        target: target,
        lineSpacing: context.lineSpacing
      )
      let snapped = Self.snapToChannels(spread, source: source, target: target)
      guard !policyCanvasRouteIntersectsObstacles(snapped, obstacles: snapValidationObstacles)
      else {
        continue
      }
      let route = PolicyCanvasEdgeRoute(
        points: snapped,
        labelPosition: Self.labelPosition(for: snapped)
      )
      let cost = Self.routeCost(points: snapped)
      if let current = best {
        if cost < current.cost {
          best = (route, cost)
        }
      } else {
        best = (route, cost)
      }
    }
    return best?.route
  }

  func simpleVisibilityCandidatePoints(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> [[CGPoint]] {
    var candidates: [[CGPoint]] = []
    var seen: Set<String> = []

    func append(_ points: [CGPoint]) {
      let compressed = Self.compressCollinear(points)
      let key =
        compressed
        .map { "\(Self.quantizedCoordinate($0.x)):\(Self.quantizedCoordinate($0.y))" }
        .joined(separator: "|")
      guard seen.insert(key).inserted else {
        return
      }
      candidates.append(compressed)
    }

    if let corridorHint = context.corridorHint {
      let y = corridorHint.horizontalLaneY
      append([
        source,
        CGPoint(x: source.x, y: y),
        CGPoint(x: target.x, y: y),
        target,
      ])
      if let x = corridorHint.verticalLaneX {
        append([
          source,
          CGPoint(x: x, y: source.y),
          CGPoint(x: x, y: target.y),
          target,
        ])
      }
      return candidates
    }

    if abs(source.x - target.x) < 0.001 || abs(source.y - target.y) < 0.001 {
      append([source, target])
    }
    append([
      source,
      CGPoint(x: target.x, y: source.y),
      target,
    ])
    append([
      source,
      CGPoint(x: source.x, y: target.y),
      target,
    ])
    return candidates
  }

  func searchObstacles(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext,
    prepared: [CGRect]
  ) -> [CGRect] {
    guard prepared.count > 12 else {
      return prepared
    }
    let candidatePoints = simpleVisibilityCandidatePoints(
      source: source,
      target: target,
      context: context
    )
    let anchorBounds =
      candidatePoints.isEmpty
      ? routeBounds([source, target])
      : candidatePoints.reduce(into: CGRect.null) { partial, points in
        partial = partial.union(routeBounds(points))
      }
    let clearance = max(
      PolicyCanvasLayout.nodeSize.width,
      PolicyCanvasLayout.nodeSize.height,
      context.lineSpacing * 8
    )
    let searchBounds = anchorBounds.insetBy(dx: -clearance, dy: -clearance)
    let local = prepared.filter { $0.intersects(searchBounds) }
    return local.isEmpty ? prepared : local
  }

  func routeBounds(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else {
      return .null
    }
    return points.dropFirst().reduce(into: CGRect(origin: first, size: .zero)) { result, point in
      result = result.union(CGRect(origin: point, size: .zero))
    }
  }
}
