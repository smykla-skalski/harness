import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasRouteWorkerOutputSignature: Equatable, Sendable {
  static let empty = Self(
    routes: [:],
    labelPositions: [:],
    portVisibility: [:],
    visibleBounds: CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize),
    contentSize: PolicyCanvasLayout.minimumCanvasSize,
    accessibilityNodeEntries: [],
    accessibilityEdgeEntries: [],
    nodeAccessibilityValuesByID: [:],
    connectTargetsByNodeID: [:]
  )

  let routeCount: Int
  let labelCount: Int
  let visiblePortCount: Int
  let accessibilityNodeCount: Int
  let accessibilityEdgeCount: Int
  let connectTargetCount: Int
  let checksum: Int

  init(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    visibleBounds: CGRect,
    contentSize: CGSize,
    accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    nodeAccessibilityValuesByID: [String: String],
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  ) {
    routeCount = routes.count
    labelCount = labelPositions.count
    visiblePortCount = portVisibility.count
    accessibilityNodeCount = accessibilityNodeEntries.count
    accessibilityEdgeCount = accessibilityEdgeEntries.count
    connectTargetCount = connectTargetsByNodeID.values.reduce(0) { $0 + $1.count }

    var hasher = Hasher()
    hasher.combine(routeCount)
    hasher.combine(labelCount)
    hasher.combine(visiblePortCount)
    hasher.combine(accessibilityNodeCount)
    hasher.combine(accessibilityEdgeCount)
    hasher.combine(connectTargetCount)
    Self.combine(rect: visibleBounds, into: &hasher)
    Self.combine(size: contentSize, into: &hasher)
    Self.combine(routes: routes, into: &hasher)
    Self.combine(labelPositions: labelPositions, into: &hasher)
    Self.combine(portVisibility: portVisibility, into: &hasher)
    Self.combine(nodeEntries: accessibilityNodeEntries, into: &hasher)
    Self.combine(edgeEntries: accessibilityEdgeEntries, into: &hasher)
    Self.combine(valuesByID: nodeAccessibilityValuesByID, into: &hasher)
    Self.combine(connectTargetsByNodeID: connectTargetsByNodeID, into: &hasher)
    checksum = hasher.finalize()
  }

  private static func combine(
    routes: [String: PolicyCanvasEdgeRoute],
    into hasher: inout Hasher
  ) {
    for key in routes.keys.sorted() {
      hasher.combine(key)
      guard let route = routes[key] else { continue }
      for point in route.points {
        combine(point: point, into: &hasher)
      }
      combine(point: route.labelPosition, into: &hasher)
    }
  }

  private static func combine(
    labelPositions: [String: CGPoint],
    into hasher: inout Hasher
  ) {
    for key in labelPositions.keys.sorted() {
      hasher.combine(key)
      if let point = labelPositions[key] {
        combine(point: point, into: &hasher)
      }
    }
  }

  private static func combine(
    portVisibility: PolicyCanvasPortVisibilityMap,
    into hasher: inout Hasher
  ) {
    for endpoint in portVisibility.keys.sorted(by: compareEndpoints) {
      hasher.combine(endpoint)
      for side in portVisibility[endpoint, default: []].sorted(by: { $0.rawValue < $1.rawValue }) {
        hasher.combine(side.rawValue)
      }
    }
  }

  private static func combine(
    nodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    into hasher: inout Hasher
  ) {
    for entry in nodeEntries {
      hasher.combine(entry.id)
      hasher.combine(entry.label)
    }
  }

  private static func combine(
    edgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    into hasher: inout Hasher
  ) {
    for entry in edgeEntries {
      hasher.combine(entry.id)
      hasher.combine(entry.label)
    }
  }

  private static func combine(
    valuesByID: [String: String],
    into hasher: inout Hasher
  ) {
    for key in valuesByID.keys.sorted() {
      hasher.combine(key)
      hasher.combine(valuesByID[key])
    }
  }

  private static func combine(
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]],
    into hasher: inout Hasher
  ) {
    for key in connectTargetsByNodeID.keys.sorted() {
      hasher.combine(key)
      for target in connectTargetsByNodeID[key] ?? [] {
        hasher.combine(target.endpoint)
        hasher.combine(target.displayName)
      }
    }
  }

  private static func compareEndpoints(
    _ left: PolicyCanvasPortEndpoint,
    _ right: PolicyCanvasPortEndpoint
  ) -> Bool {
    if left.nodeID != right.nodeID { return left.nodeID < right.nodeID }
    if left.portID != right.portID { return left.portID < right.portID }
    if left.kind != right.kind { return left.kind.rawValue < right.kind.rawValue }
    return (left.side?.rawValue ?? "") < (right.side?.rawValue ?? "")
  }

  private static func combine(point: CGPoint, into hasher: inout Hasher) {
    hasher.combine(point.x)
    hasher.combine(point.y)
  }

  private static func combine(size: CGSize, into hasher: inout Hasher) {
    hasher.combine(size.width)
    hasher.combine(size.height)
  }

  private static func combine(rect: CGRect, into hasher: inout Hasher) {
    combine(point: rect.origin, into: &hasher)
    combine(size: rect.size, into: &hasher)
  }
}
