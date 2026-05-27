import SwiftUI

struct PolicyCanvasLabelPlacementRoute {
  let id: String
  let label: String
  let route: PolicyCanvasEdgeRoute
  let size: CGSize
}

func policyCanvasRouteFrames(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: [CGRect]] {
  policyCanvasRouteFrames(routes.map { (id: $0.id, route: $0.route) })
}

func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  labelSize: CGSize
) -> [String: CGPoint] {
  let placementRoutes = routes.map {
    PolicyCanvasLabelPlacementRoute(
      id: $0.id,
      label: $0.id,
      route: $0.route,
      size: labelSize
    )
  }
  return policyCanvasResolvedLabelPositions(
    routes: placementRoutes,
    nodeFrames: nodeFrames,
    routeFrames: [:]
  )
}

func policyCanvasResolvedLabelPositions(
  routes: [(id: String, route: PolicyCanvasEdgeRoute)],
  nodeFrames: [CGRect],
  routeFrames: [String: [CGRect]],
  labelSize: CGSize
) -> [String: CGPoint] {
  let placementRoutes = routes.map {
    PolicyCanvasLabelPlacementRoute(
      id: $0.id,
      label: $0.id,
      route: $0.route,
      size: labelSize
    )
  }
  return policyCanvasResolvedLabelPositions(
    routes: placementRoutes,
    nodeFrames: nodeFrames,
    routeFrames: routeFrames
  )
}

func policyCanvasResolvedLabelPositions(
  routes: [PolicyCanvasLabelPlacementRoute],
  nodeFrames: [CGRect],
  routeFrames: [String: [CGRect]]
) -> [String: CGPoint] {
  let sharedTrunkAvoidance = policyCanvasSharedTrunkLabelAvoidance(routes)
  var occupiedFrames: [CGRect] = []
  var positions: [String: CGPoint] = [:]
  for entry in policyCanvasSortedLabelRoutes(routes) {
    let blockingRouteFrames = routeFrames.reduce(into: [CGRect]()) { result, element in
      if element.key != entry.id {
        result.append(contentsOf: element.value)
      }
    }
    let position = policyCanvasResolvedLabelPosition(
      route: entry.route,
      size: entry.size,
      avoidDominantHorizontalSegment: sharedTrunkAvoidance.contains(entry.id),
      occupiedFrames: occupiedFrames,
      nodeFrames: nodeFrames,
      routeFrames: blockingRouteFrames
    )
    positions[entry.id] = position
    occupiedFrames.append(policyCanvasLabelFrame(center: position, size: entry.size))
  }
  return positions
}

private func policyCanvasSortedLabelRoutes(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [PolicyCanvasLabelPlacementRoute] {
  routes.sorted { left, right in
    if left.route.labelPosition.y != right.route.labelPosition.y {
      return left.route.labelPosition.y < right.route.labelPosition.y
    }
    if left.route.labelPosition.x != right.route.labelPosition.x {
      return left.route.labelPosition.x < right.route.labelPosition.x
    }
    return left.id < right.id
  }
}

private func policyCanvasResolvedLabelPosition(
  route: PolicyCanvasEdgeRoute,
  size: CGSize,
  avoidDominantHorizontalSegment: Bool,
  occupiedFrames: [CGRect],
  nodeFrames: [CGRect],
  routeFrames: [CGRect]
) -> CGPoint {
  for candidate in policyCanvasLabelCandidates(
    route: route,
    labelSize: size,
    avoidDominantHorizontalSegment: avoidDominantHorizontalSegment
  ) {
    let frame = policyCanvasLabelFrame(center: candidate, size: size)
    if !occupiedFrames.contains(where: { $0.intersects(frame) })
      && !nodeFrames.contains(where: { $0.intersects(frame) })
      && !routeFrames.contains(where: { $0.intersects(frame) })
    {
      return candidate
    }
  }
  return policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
}

private func policyCanvasLabelCandidates(
  route: PolicyCanvasEdgeRoute,
  labelSize: CGSize,
  avoidDominantHorizontalSegment: Bool
) -> [CGPoint] {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let segments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidDominantHorizontalSegment: avoidDominantHorizontalSegment
  )
  var candidates: [CGPoint] = []
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: true
      ))
  }
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: false
      ))
  }
  var seen: Set<CGPoint> = []
  return candidates.filter { seen.insert($0).inserted }
}

private func policyCanvasRankedLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidDominantHorizontalSegment: Bool
) -> [PolicyCanvasLabelRouteSegment] {
  let avoidedSegment = avoidDominantHorizontalSegment
    ? policyCanvasDominantHorizontalLabelSegment(route: route)
    : nil
  return zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .sorted { left, right in
      if let avoidedSegment {
        let leftAvoided = left.matches(avoidedSegment)
        let rightAvoided = right.matches(avoidedSegment)
        if leftAvoided != rightAvoided {
          return !leftAvoided
        }
      }
      if left.containsProjection(of: base) != right.containsProjection(of: base) {
        return left.containsProjection(of: base)
      }
      if left.isHorizontal != right.isHorizontal {
        return left.isHorizontal
      }
      let leftDistance = left.distanceSquared(to: base)
      let rightDistance = right.distanceSquared(to: base)
      if abs(leftDistance - rightDistance) > 0.001 {
        return leftDistance < rightDistance
      }
      return left.length > right.length
    }
}

private func policyCanvasLabelCandidates(
  on segment: PolicyCanvasLabelRouteSegment,
  base: CGPoint,
  size: CGSize,
  keepsCornerClearance: Bool
) -> [CGPoint] {
  let labelAxisLength = segment.isHorizontal ? size.width : size.height
  let tRange: ClosedRange<CGFloat>?
  if keepsCornerClearance {
    tRange = segment.cornerClearRange(for: labelAxisLength)
  } else {
    tRange = segment.safeRange(for: labelAxisLength)
  }
  guard let tRange else {
    return []
  }
  let baseT = min(max(segment.parameter(for: base), tRange.lowerBound), tRange.upperBound)
  let step = max(labelAxisLength + 12, PolicyCanvasLayout.gridSize * 2)
  let stepT = segment.length > 0 ? step / segment.length : 0
  var values: [CGFloat] = [0.5, baseT, tRange.lowerBound, tRange.upperBound, 0.25, 0.75]
  for index in 1..<6 {
    values.append(baseT + (policyCanvasSignedLaneOffset(index: index, spacing: stepT)))
  }
  return values.map { value in
    segment.point(at: min(max(value, tRange.lowerBound), tRange.upperBound))
  }
}

private func policyCanvasSharedTrunkLabelAvoidance(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> Set<String> {
  var bundles: [PolicyCanvasSharedLabelBundle] = []
  for entry in policyCanvasSortedLabelRoutes(routes) {
  guard let segment = policyCanvasDominantHorizontalLabelSegment(route: entry.route) else {
    continue
  }
  if let bundleIndex = bundles.firstIndex(where: { $0.matches(segment) }) {
    bundles[bundleIndex].append(entry.id, segment: segment)
  } else {
    bundles.append(PolicyCanvasSharedLabelBundle(routeID: entry.id, segment: segment))
  }
  }
  return bundles.reduce(into: Set<String>()) { result, bundle in
  guard bundle.routeIDs.count > 1 else {
    return
  }
  for routeID in bundle.routeIDs.dropFirst() {
    result.insert(routeID)
  }
  }
}

private func policyCanvasDominantHorizontalLabelSegment(
  route: PolicyCanvasEdgeRoute
) -> PolicyCanvasSharedLabelSegment? {
  zip(route.points, route.points.dropFirst())
  .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  .filter(\.isHorizontal)
  .max { left, right in
    if abs(left.length - right.length) > 0.001 {
      return left.length < right.length
    }
    return min(left.start.x, left.end.x) > min(right.start.x, right.end.x)
  }
  .map(PolicyCanvasSharedLabelSegment.init(segment:))
}

private func policyCanvasClosestRoutePoint(
  to point: CGPoint,
  route: PolicyCanvasEdgeRoute
) -> CGPoint {
  let segments = zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
  return segments.min { left, right in
    left.distanceSquared(to: point) < right.distanceSquared(to: point)
  }?.closestPoint(to: point) ?? route.points.first ?? point
}

private func policyCanvasLabelFrame(center: CGPoint, size: CGSize) -> CGRect {
  CGRect(
    x: center.x - (size.width / 2),
    y: center.y - (size.height / 2),
    width: size.width,
    height: size.height
  )
}

private struct PolicyCanvasLabelRouteSegment {
  let start: CGPoint
  let end: CGPoint
  let lengthSquared: CGFloat
  let length: CGFloat

  init?(start: CGPoint, end: CGPoint) {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = (dx * dx) + (dy * dy)
    guard lengthSquared > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
    self.lengthSquared = lengthSquared
    self.length = sqrt(lengthSquared)
  }

  var isHorizontal: Bool {
    abs(end.x - start.x) >= abs(end.y - start.y)
  }

  var xRange: ClosedRange<CGFloat> {
    min(start.x, end.x)...max(start.x, end.x)
  }

  func safeRange(for labelAxisLength: CGFloat) -> ClosedRange<CGFloat> {
    guard length > labelAxisLength else {
      return 0.5...0.5
    }
    let inset = (labelAxisLength / 2) / length
    return inset...(1 - inset)
  }

  func cornerClearRange(for labelAxisLength: CGFloat) -> ClosedRange<CGFloat>? {
    let endpointClearance = (labelAxisLength / 2) + PolicyCanvasLayout.gridSize
    guard length > endpointClearance * 2 else {
      return nil
    }
    let inset = endpointClearance / length
    return inset...(1 - inset)
  }

  func containsProjection(of point: CGPoint) -> Bool {
    let parameter = parameter(for: point)
    return parameter >= 0 && parameter <= 1
  }

  func parameter(for point: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    return (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared
  }

  func point(at parameter: CGFloat) -> CGPoint {
    CGPoint(
      x: start.x + ((end.x - start.x) * parameter),
      y: start.y + ((end.y - start.y) * parameter)
    )
  }

  func closestPoint(to point: CGPoint) -> CGPoint {
    self.point(at: min(max(parameter(for: point), 0), 1))
  }

  func distanceSquared(to point: CGPoint) -> CGFloat {
    let closest = closestPoint(to: point)
    let dx = closest.x - point.x
    let dy = closest.y - point.y
    return (dx * dx) + (dy * dy)
  }

  func matches(_ segment: PolicyCanvasSharedLabelSegment) -> Bool {
    isHorizontal
      && abs(start.y - segment.y) < 0.5
      && abs(xRange.lowerBound - segment.range.lowerBound) < 0.5
      && abs(xRange.upperBound - segment.range.upperBound) < 0.5
  }
}

private struct PolicyCanvasSharedLabelSegment {
  let y: CGFloat
  let range: ClosedRange<CGFloat>

  init(segment: PolicyCanvasLabelRouteSegment) {
    y = segment.start.y
    range = segment.xRange
  }
}

private struct PolicyCanvasSharedLabelBundle {
  private static let minimumSharedOverlap = PolicyCanvasLayout.gridSize * 4

  var y: CGFloat
  var sharedRange: ClosedRange<CGFloat>
  var routeIDs: [String]

  init(routeID: String, segment: PolicyCanvasSharedLabelSegment) {
    y = segment.y
    sharedRange = segment.range
    routeIDs = [routeID]
  }

  mutating func append(_ routeID: String, segment: PolicyCanvasSharedLabelSegment) {
    let lowerBound = max(sharedRange.lowerBound, segment.range.lowerBound)
    let upperBound = min(sharedRange.upperBound, segment.range.upperBound)
    sharedRange = lowerBound...upperBound
    routeIDs.append(routeID)
  }

  func matches(_ segment: PolicyCanvasSharedLabelSegment) -> Bool {
    abs(y - segment.y) < 0.5
      && policyCanvasSharedLabelOverlap(sharedRange, segment.range) >= Self.minimumSharedOverlap
  }
}

private func policyCanvasSharedLabelOverlap(
  _ left: ClosedRange<CGFloat>,
  _ right: ClosedRange<CGFloat>
) -> CGFloat {
  max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
}
