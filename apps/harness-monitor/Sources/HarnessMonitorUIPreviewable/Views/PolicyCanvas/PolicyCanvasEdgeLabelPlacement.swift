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
  let sharedSegmentAvoidance = policyCanvasSharedSegmentLabelAvoidance(routes)
  let secondaryDuplicateLabels = policyCanvasSecondaryDuplicateLabelIDs(routes)
  var occupiedFrames: [CGRect] = []
  var positions: [String: CGPoint] = [:]
  for entry in policyCanvasSortedLabelRoutes(routes) {
    let blockingRouteFrames = routeFrames.reduce(into: [CGRect]()) { result, element in
      if element.key != entry.id {
        result.append(contentsOf: element.value)
      }
    }
    let avoidedSegments = sharedSegmentAvoidance[entry.id, default: []]
    let preferredAxis = policyCanvasPreferredLabelAxis(
      avoidedSegments: avoidedSegments,
      preferVerticalSegments: secondaryDuplicateLabels.contains(entry.id)
    )
    let position = policyCanvasResolvedLabelPosition(
      route: entry.route,
      size: entry.size,
      avoidedSegments: avoidedSegments,
      preferredAxis: preferredAxis,
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
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?,
  occupiedFrames: [CGRect],
  nodeFrames: [CGRect],
  routeFrames: [CGRect]
) -> CGPoint {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let preferredSegments = policyCanvasPreferredLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  if !preferredSegments.isEmpty {
    for candidate in policyCanvasLabelCandidates(
      segments: preferredSegments,
      base: base,
      labelSize: size,
      preferredAxis: preferredAxis
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
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
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
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [CGPoint] {
  let base = policyCanvasClosestRoutePoint(to: route.labelPosition, route: route)
  let segments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  return policyCanvasLabelCandidates(
    segments: segments,
    base: base,
    labelSize: labelSize,
    preferredAxis: preferredAxis
  )
}

private func policyCanvasLabelCandidates(
  segments: [PolicyCanvasLabelRouteSegment],
  base: CGPoint,
  labelSize: CGSize,
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [CGPoint] {
  var candidates: [CGPoint] = []
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: true,
        preferAdjacentVerticalPlacement: preferredAxis == .vertical && !segment.isHorizontal,
        preferAdjacentHorizontalPlacement: preferredAxis == .horizontal && segment.isHorizontal
      ))
  }
  for segment in segments {
    candidates.append(
      contentsOf: policyCanvasLabelCandidates(
        on: segment,
        base: base,
        size: labelSize,
        keepsCornerClearance: false,
        preferAdjacentVerticalPlacement: preferredAxis == .vertical && !segment.isHorizontal,
        preferAdjacentHorizontalPlacement: preferredAxis == .horizontal && segment.isHorizontal
      ))
  }
  var seen: Set<CGPoint> = []
  return candidates.filter { seen.insert($0).inserted }
}

private func policyCanvasPreferredLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [PolicyCanvasLabelRouteSegment] {
  let rankedSegments = policyCanvasRankedLabelSegments(
    route: route,
    base: base,
    avoidedSegments: avoidedSegments,
    preferredAxis: preferredAxis
  )
  let nonAvoidedSegments = rankedSegments.filter { segment in
    !segment.matchesAny(avoidedSegments)
  }
  if let preferredAxis {
    let axisSegments = nonAvoidedSegments.filter { $0.axis == preferredAxis }
    if !axisSegments.isEmpty {
      return axisSegments
    }
  }
  if !nonAvoidedSegments.isEmpty, !avoidedSegments.isEmpty {
    return nonAvoidedSegments
  }
  return []
}

private func policyCanvasRankedLabelSegments(
  route: PolicyCanvasEdgeRoute,
  base: CGPoint,
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferredAxis: PolicyCanvasSegmentAxis?
) -> [PolicyCanvasLabelRouteSegment] {
  return zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .sorted { left, right in
      let leftAvoided = left.matchesAny(avoidedSegments)
      let rightAvoided = right.matchesAny(avoidedSegments)
      if leftAvoided != rightAvoided {
        return !leftAvoided
      }
      if let preferredAxis, left.axis != right.axis {
        return left.axis == preferredAxis
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
  preferAdjacentVerticalPlacement: Bool,
  preferAdjacentHorizontalPlacement: Bool
) -> [CGPoint] {
  let labelAxisLength = segment.isHorizontal ? size.width : size.height
  let tRange: ClosedRange<CGFloat>?
  if keepsCornerClearance {
    tRange = segment.cornerClearRange(for: labelAxisLength)
  } else {
    tRange = segment.safeRange(for: labelAxisLength)
  }
  let parameters: [CGFloat]
  if let tRange {
    let baseT = min(max(segment.parameter(for: base), tRange.lowerBound), tRange.upperBound)
    let step = max(labelAxisLength + 12, PolicyCanvasLayout.gridSize * 2)
    let stepT = segment.length > 0 ? step / segment.length : 0
    var values: [CGFloat] = [0.5, baseT, tRange.lowerBound, tRange.upperBound, 0.25, 0.75]
    for index in 1..<6 {
      values.append(baseT + (policyCanvasSignedLaneOffset(index: index, spacing: stepT)))
    }
    parameters = values.map { value in
      min(max(value, tRange.lowerBound), tRange.upperBound)
    }
  } else if preferAdjacentVerticalPlacement || preferAdjacentHorizontalPlacement {
    parameters = [0.5]
  } else {
    return []
  }
  let points = parameters.map(segment.point(at:))
  guard preferAdjacentVerticalPlacement || preferAdjacentHorizontalPlacement else {
    return points
  }
  var candidates: [CGPoint] = []
  for point in points {
    if preferAdjacentVerticalPlacement {
      candidates.append(
        contentsOf: policyCanvasAdjacentVerticalLabelCandidates(
          point: point,
          base: base,
          labelWidth: size.width
        )
      )
    }
    if preferAdjacentHorizontalPlacement {
      candidates.append(
        contentsOf: policyCanvasAdjacentHorizontalLabelCandidates(
          point: point,
          base: base,
          labelHeight: size.height
        )
      )
    }
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

private func policyCanvasAdjacentHorizontalLabelCandidates(
  point: CGPoint,
  base: CGPoint,
  labelHeight: CGFloat
) -> [CGPoint] {
  let primaryOffset = (labelHeight / 2) + PolicyCanvasLayout.gridSize + 6
  let secondaryOffset = primaryOffset + (PolicyCanvasLayout.gridSize * 2)
  let preferredSigns: [CGFloat] = base.y >= point.y ? [-1, 1] : [1, -1]
  return [primaryOffset, secondaryOffset].flatMap { magnitude in
    preferredSigns.map { sign in
      CGPoint(x: point.x, y: point.y + (sign * magnitude))
    }
  }
}

private func policyCanvasSharedSegmentLabelAvoidance(
  _ routes: [PolicyCanvasLabelPlacementRoute]
) -> [String: [PolicyCanvasSharedLabelSegment]] {
  var bundles: [PolicyCanvasSharedLabelBundle] = []
  for entry in policyCanvasSortedLabelRoutes(routes) {
    for segment in policyCanvasSharedLabelSegments(route: entry.route) {
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
    if left.axis != right.axis {
      return left.axis == .horizontal
    }
    return left.coordinate < right.coordinate
  }
  return prioritizedBundles.reduce(into: [String: [PolicyCanvasSharedLabelSegment]]()) {
    result,
    bundle in
    guard bundle.routeIDs.count > 1 else {
      return
    }
    let avoidedSegment = PolicyCanvasSharedLabelSegment(
      axis: bundle.axis,
      coordinate: bundle.coordinate,
      range: bundle.sharedRange
    )
    for routeID in bundle.routeIDs.dropFirst() {
      result[routeID, default: []].append(avoidedSegment)
    }
  }
}

private func policyCanvasSharedLabelSegments(
  route: PolicyCanvasEdgeRoute
) -> [PolicyCanvasSharedLabelSegment] {
  zip(route.points, route.points.dropFirst())
    .compactMap(PolicyCanvasLabelRouteSegment.init(start:end:))
    .filter { $0.length >= policyCanvasMinimumSharedLabelOverlap }
    .map(PolicyCanvasSharedLabelSegment.init(segment:))
}

private func policyCanvasPreferredLabelAxis(
  avoidedSegments: [PolicyCanvasSharedLabelSegment],
  preferVerticalSegments: Bool
) -> PolicyCanvasSegmentAxis? {
  let avoidsHorizontal = avoidedSegments.contains(where: { $0.axis == .horizontal })
  let avoidsVertical = avoidedSegments.contains(where: { $0.axis == .vertical })
  if avoidsHorizontal != avoidsVertical {
    return avoidsHorizontal ? .vertical : .horizontal
  }
  if avoidsHorizontal, avoidsVertical {
    return .horizontal
  }
  if preferVerticalSegments {
    return .vertical
  }
  return nil
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

  var axis: PolicyCanvasSegmentAxis {
    isHorizontal ? .horizontal : .vertical
  }

  var xRange: ClosedRange<CGFloat> {
    min(start.x, end.x)...max(start.x, end.x)
  }

  var yRange: ClosedRange<CGFloat> {
    min(start.y, end.y)...max(start.y, end.y)
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
    guard axis == segment.axis else {
      return false
    }
    switch axis {
    case .horizontal:
      return abs(start.y - segment.coordinate) < 0.5
        && policyCanvasSharedLabelOverlap(xRange, segment.range)
          >= policyCanvasMinimumSharedLabelOverlap
    case .vertical:
      return abs(start.x - segment.coordinate) < 0.5
        && policyCanvasSharedLabelOverlap(yRange, segment.range)
          >= policyCanvasMinimumSharedLabelOverlap
    }
  }

  func matchesAny(_ segments: [PolicyCanvasSharedLabelSegment]) -> Bool {
    segments.contains { matches($0) }
  }
}

private struct PolicyCanvasSharedLabelSegment {
  let axis: PolicyCanvasSegmentAxis
  let coordinate: CGFloat
  let range: ClosedRange<CGFloat>

  init(segment: PolicyCanvasLabelRouteSegment) {
    axis = segment.axis
    coordinate = segment.isHorizontal ? segment.start.y : segment.start.x
    range = segment.isHorizontal ? segment.xRange : segment.yRange
  }

  init(axis: PolicyCanvasSegmentAxis, coordinate: CGFloat, range: ClosedRange<CGFloat>) {
    self.axis = axis
    self.coordinate = coordinate
    self.range = range
  }
}

private struct PolicyCanvasSharedLabelBundle {
  var axis: PolicyCanvasSegmentAxis
  var coordinate: CGFloat
  var sharedRange: ClosedRange<CGFloat>
  var routeIDs: [String]

  init(routeID: String, segment: PolicyCanvasSharedLabelSegment) {
    axis = segment.axis
    coordinate = segment.coordinate
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
    axis == segment.axis
      && abs(coordinate - segment.coordinate) < 0.5
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
