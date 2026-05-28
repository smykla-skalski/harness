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
  let secondaryDuplicateLabels = policyCanvasSecondaryDuplicateLabelIDs(routes)
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
      avoidedHorizontalSegment: sharedTrunkAvoidance[entry.id],
      preferVerticalSegments: secondaryDuplicateLabels.contains(entry.id),
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
  avoidedHorizontalSegment: PolicyCanvasSharedLabelSegment?,
  preferVerticalSegments: Bool,
  occupiedFrames: [CGRect],
  nodeFrames: [CGRect],
  routeFrames: [CGRect]
) -> CGPoint {
  let prefersVerticalPlacement = preferVerticalSegments || avoidedHorizontalSegment != nil
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let preferredSegments = policyCanvasPreferredLabelSegments(
    route: route,
    base: base,
    avoidedHorizontalSegment: avoidedHorizontalSegment,
    preferVerticalSegments: prefersVerticalPlacement
  )
  if !preferredSegments.isEmpty {
    for candidate in policyCanvasLabelCandidates(
      segments: preferredSegments,
      base: base,
      labelSize: size,
      preferVerticalSegments: prefersVerticalPlacement
    ) {
      let frame = policyCanvasLabelFrame(center: candidate, size: size)
      if !occupiedFrames.contains(where: { $0.intersects(frame) })
        && !nodeFrames.contains(where: { $0.intersects(frame) })
        && !routeFrames.contains(where: { $0.intersects(frame) })
      {
        return candidate
      }
    }
  }
  for candidate in policyCanvasLabelCandidates(
    route: route,
    labelSize: size,
    avoidedHorizontalSegment: avoidedHorizontalSegment,
    preferVerticalSegments: prefersVerticalPlacement
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
  avoidedHorizontalSegment: PolicyCanvasSharedLabelSegment?,
  preferVerticalSegments: Bool
) -> [CGPoint] {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let segments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedHorizontalSegment: avoidedHorizontalSegment,
    preferVerticalSegments: preferVerticalSegments
  )
  return policyCanvasLabelCandidates(
    segments: segments,
    base: base,
    labelSize: labelSize,
    preferVerticalSegments: preferVerticalSegments
  )
}

private func policyCanvasLabelCandidates(
  segments: [PolicyCanvasLabelRouteSegment],
  base: CGPoint,
  labelSize: CGSize,
  preferVerticalSegments: Bool
) -> [CGPoint] {
  var candidates: [CGPoint] = []
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: true,
        preferAdjacentVerticalPlacement: preferVerticalSegments && !segment.isHorizontal
      ))
  }
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: false,
        preferAdjacentVerticalPlacement: preferVerticalSegments && !segment.isHorizontal
      ))
  }
  var seen: Set<CGPoint> = []
  return candidates.filter { seen.insert($0).inserted }
}

private func policyCanvasPreferredLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedHorizontalSegment: PolicyCanvasSharedLabelSegment?,
  preferVerticalSegments: Bool
) -> [PolicyCanvasLabelRouteSegment] {
  let rankedSegments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedHorizontalSegment: avoidedHorizontalSegment,
    preferVerticalSegments: preferVerticalSegments
  )
  let nonAvoidedSegments = rankedSegments.filter { segment in
    guard let avoidedHorizontalSegment else {
      return true
    }
    return !segment.matches(avoidedHorizontalSegment)
  }
  let preferredVerticalSegments = nonAvoidedSegments.filter { !$0.isHorizontal }
  if preferVerticalSegments, !preferredVerticalSegments.isEmpty {
    return preferredVerticalSegments
  }
  if !nonAvoidedSegments.isEmpty, avoidedHorizontalSegment != nil {
    return nonAvoidedSegments
  }
  return []
}

private func policyCanvasRankedLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedHorizontalSegment: PolicyCanvasSharedLabelSegment?,
  preferVerticalSegments: Bool
) -> [PolicyCanvasLabelRouteSegment] {
  return zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .sorted { left, right in
      if let avoidedHorizontalSegment {
        let leftAvoided = left.matches(avoidedHorizontalSegment)
        let rightAvoided = right.matches(avoidedHorizontalSegment)
        if leftAvoided != rightAvoided {
          return !leftAvoided
        }
      }
      if preferVerticalSegments, left.isHorizontal != right.isHorizontal {
        return !left.isHorizontal
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

private func policyCanvasSecondaryDuplicateLabelIDs(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> Set<String> {
  let sortedRoutes = policyCanvasSortedLabelRoutes(routes)
  let duplicateGroups = Dictionary(grouping: sortedRoutes) { route in
    route.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  return duplicateGroups.reduce(into: Set<String>()) { result, entry in
    let label = entry.key
    let groupedRoutes = entry.value
    guard !label.isEmpty, groupedRoutes.count > 1 else {
      return
    }
    for route in groupedRoutes.dropFirst() {
      result.insert(route.id)
    }
  }
}

private func policyCanvasLabelCandidates(
  on segment: PolicyCanvasLabelRouteSegment,
  base: CGPoint,
  size: CGSize,
  keepsCornerClearance: Bool,
  preferAdjacentVerticalPlacement: Bool
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
  let points = values.map { value in
    segment.point(at: min(max(value, tRange.lowerBound), tRange.upperBound))
  }
  guard preferAdjacentVerticalPlacement else {
    return points
  }
  var candidates: [CGPoint] = []
  for point in points {
    candidates.append(
      contentsOf: policyCanvasAdjacentVerticalLabelCandidates(
        point: point,
        base: base,
        labelWidth: size.width
      )
    )
    candidates.append(point)
  }
  return candidates
}

private func policyCanvasAdjacentVerticalLabelCandidates(
  point: CGPoint,
  base: CGPoint,
  labelWidth: CGFloat
) -> [CGPoint] {
  let primaryOffset = (labelWidth / 2) + PolicyCanvasLayout.gridSize + 6
  let secondaryOffset = primaryOffset + (PolicyCanvasLayout.gridSize * 2)
  let preferredSigns: [CGFloat] = base.x >= point.x ? [-1, 1] : [1, -1]
  return [primaryOffset, secondaryOffset].flatMap { magnitude in
    preferredSigns.map { sign in
      CGPoint(x: point.x + (sign * magnitude), y: point.y)
    }
  }
}

private func policyCanvasSharedTrunkLabelAvoidance(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: PolicyCanvasSharedLabelSegment] {
  var bundles: [PolicyCanvasSharedLabelBundle] = []
  for entry in policyCanvasSortedLabelRoutes(routes) {
    for segment in policyCanvasHorizontalLabelSegments(route: entry.route) {
      if let bundleIndex = bundles.firstIndex(where: {
        $0.matches(segment) && !$0.routeIDs.contains(entry.id)
      }) {
        bundles[bundleIndex].append(entry.id, segment: segment)
      } else {
        bundles.append(PolicyCanvasSharedLabelBundle(routeID: entry.id, segment: segment))
      }
    }
  }
  let prioritizedBundles = bundles.sorted { left, right in
    if left.routeIDs.count != right.routeIDs.count {
      return left.routeIDs.count > right.routeIDs.count
    }
    let leftOverlap = left.sharedRange.upperBound - left.sharedRange.lowerBound
    let rightOverlap = right.sharedRange.upperBound - right.sharedRange.lowerBound
    if abs(leftOverlap - rightOverlap) > 0.001 {
      return leftOverlap > rightOverlap
    }
    return left.y < right.y
  }
  return prioritizedBundles.reduce(into: [String: PolicyCanvasSharedLabelSegment]()) {
    result,
    bundle in
    guard bundle.routeIDs.count > 1 else {
      return
    }
    let avoidedSegment = PolicyCanvasSharedLabelSegment(y: bundle.y, range: bundle.sharedRange)
    for routeID in bundle.routeIDs.dropFirst() where result[routeID] == nil {
      result[routeID] = avoidedSegment
    }
  }
}

private func policyCanvasHorizontalLabelSegments(
  route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasSharedLabelSegment] {
  zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .filter(\.isHorizontal)
    .filter { $0.length >= policyCanvasMinimumSharedLabelOverlap }
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
      && policyCanvasSharedLabelOverlap(xRange, segment.range)
        >= policyCanvasMinimumSharedLabelOverlap
  }
}

private struct PolicyCanvasSharedLabelSegment {
  let y: CGFloat
  let range: ClosedRange<CGFloat>

  init(segment: PolicyCanvasLabelRouteSegment) {
    y = segment.start.y
    range = segment.xRange
  }

  init(y: CGFloat, range: ClosedRange<CGFloat>) {
    self.y = y
    self.range = range
  }
}

private struct PolicyCanvasSharedLabelBundle {
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
      && policyCanvasSharedLabelOverlap(sharedRange, segment.range)
        >= policyCanvasMinimumSharedLabelOverlap
  }
}

private let policyCanvasMinimumSharedLabelOverlap = PolicyCanvasLayout.gridSize * 4

private func policyCanvasSharedLabelOverlap(
  _ left: ClosedRange<CGFloat>,
  _ right: ClosedRange<CGFloat>
) -> CGFloat {
  max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
}
