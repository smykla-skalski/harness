import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private let policyCanvasNativeEdgeHitRadius: CGFloat = 6

extension PolicyCanvasViewModel {
  func canvasHitTarget(
    at point: CGPoint,
    portVisibility: PolicyCanvasPortVisibilityMap = [:],
    portMarkerLayout: PolicyCanvasPortMarkerLayout = .empty
  ) -> PolicyCanvasCanvasHitTarget? {
    if let port = canvasPortHitTarget(
      at: point,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout
    ) {
      return .port(port)
    }
    if let node = nodes.reversed().first(where: { nodeFrame(for: $0).contains(point) }) {
      return .node(node.id)
    }
    if let group = groups.reversed().first(where: { $0.frame.contains(point) }) {
      return .group(group.id)
    }
    return nil
  }

  func canvasPointerSelectionTarget(
    at point: CGPoint,
    portVisibility: PolicyCanvasPortVisibilityMap = [:],
    portMarkerLayout: PolicyCanvasPortMarkerLayout = .empty
  ) -> PolicyCanvasSelection? {
    switch canvasHitTarget(
      at: point,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout
    ) {
    case .node(let id):
      return .node(id)
    case .group(let id):
      return .group(id)
    case .edge(let id):
      return .edge(id)
    case .port, nil:
      return nil
    }
  }

  func canvasPointerHitTarget(
    at point: CGPoint,
    portVisibility: PolicyCanvasPortVisibilityMap = [:],
    portMarkerLayout: PolicyCanvasPortMarkerLayout = .empty,
    routes: [String: PolicyCanvasEdgeRoute] = [:]
  ) -> PolicyCanvasCanvasHitTarget? {
    let portRadius =
      (PolicyCanvasLayout.portDiameter / 2) + PolicyCanvasLayout.portHitTestExtension
    for node in nodes.reversed() {
      let nodeFrame = nodeFrame(for: node)
      if nodeFrame.insetBy(dx: -portRadius, dy: -portRadius).contains(point),
        let port = canvasPortHitTarget(
          at: point,
          node: node,
          portVisibility: portVisibility,
          portMarkerLayout: portMarkerLayout
        )
      {
        return .port(port)
      }
      if nodeFrame.contains(point) {
        return .node(node.id)
      }
    }
    if let edgeID = canvasEdgeHitTarget(at: point, routes: routes) {
      return .edge(edgeID)
    }
    if let group = groups.reversed().first(where: { $0.frame.contains(point) }) {
      return .group(group.id)
    }
    return nil
  }

  func canvasEdgeHitTarget(
    at point: CGPoint,
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> String? {
    guard !routes.isEmpty else {
      return nil
    }
    let radiusSquared = policyCanvasNativeEdgeHitRadius * policyCanvasNativeEdgeHitRadius
    for edge in edges.reversed() {
      guard let route = routes[edge.id],
        policyCanvasRouteDistanceSquared(to: point, route: route) <= radiusSquared
      else {
        continue
      }
      return edge.id
    }
    return nil
  }

  func canvasInputPortHitTarget(
    at point: CGPoint,
    portVisibility: PolicyCanvasPortVisibilityMap = [:],
    portMarkerLayout: PolicyCanvasPortMarkerLayout = .empty
  ) -> PolicyCanvasPortEndpoint? {
    canvasPortHitTarget(
      at: point,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout,
      allowedKind: .input
    )
  }

  private func canvasPortHitTarget(
    at point: CGPoint,
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    allowedKind: PolicyCanvasPortKind? = nil
  ) -> PolicyCanvasPortEndpoint? {
    for node in nodes.reversed() {
      if let port = canvasPortHitTarget(
        at: point,
        node: node,
        portVisibility: portVisibility,
        portMarkerLayout: portMarkerLayout,
        allowedKind: allowedKind
      ) {
        return port
      }
    }
    return nil
  }

  private func canvasPortHitTarget(
    at point: CGPoint,
    node: PolicyCanvasNode,
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    allowedKind: PolicyCanvasPortKind? = nil
  ) -> PolicyCanvasPortEndpoint? {
    let radius = (PolicyCanvasLayout.portDiameter / 2) + PolicyCanvasLayout.portHitTestExtension
    let portsByKind: [(PolicyCanvasPortKind, [PolicyCanvasPort])] = [
      (.input, node.inputPorts),
      (.output, node.outputPorts),
    ]
    for (kind, ports) in portsByKind where allowedKind == nil || allowedKind == kind {
      for index in ports.indices.reversed() {
        let port = ports[index]
        let baseEndpoint = PolicyCanvasPortEndpoint(
          nodeID: node.id,
          portID: port.id,
          kind: kind
        )
        let visibleSides = policyCanvasVisiblePortSides(
          for: baseEndpoint,
          visibility: portVisibility,
          nodeIsActive: isSelected(.node(node.id)),
          hasPendingEdge: hasPendingEdge
        )
        for side in visibleSides {
          let sidedEndpoint = PolicyCanvasPortEndpoint(
            nodeID: node.id,
            portID: port.id,
            kind: kind,
            side: side
          )
          let markers = portMarkerLayout.markers(
            for: sidedEndpoint,
            side: side,
            isVisible: true
          )
          for marker in markers where marker.allowsInteraction {
            let anchor = policyCanvasShiftedRouteAnchor(
              portAnchor(for: node, side: side, index: index, count: ports.count),
              side: side,
              terminal: PolicyCanvasPortTerminal(side: side, axisOffset: marker.axisOffset)
            )
            if hypot(point.x - anchor.x, point.y - anchor.y) <= radius {
              return sidedEndpoint
            }
          }
        }
      }
    }
    return nil
  }
}

private func policyCanvasRouteDistanceSquared(
  to point: CGPoint,
  route: PolicyCanvasEdgeRoute
) -> CGFloat {
  guard let first = route.points.first else {
    return .greatestFiniteMagnitude
  }
  guard route.points.count > 1 else {
    return policyCanvasDistanceSquared(point, first)
  }
  var best = CGFloat.greatestFiniteMagnitude
  for (start, end) in zip(route.points, route.points.dropFirst()) {
    best = min(best, policyCanvasDistanceSquared(from: point, toSegmentStart: start, end: end))
  }
  return best
}

private func policyCanvasDistanceSquared(
  from point: CGPoint,
  toSegmentStart start: CGPoint,
  end: CGPoint
) -> CGFloat {
  let dx = end.x - start.x
  let dy = end.y - start.y
  let lengthSquared = (dx * dx) + (dy * dy)
  guard lengthSquared > .ulpOfOne else {
    return policyCanvasDistanceSquared(point, start)
  }
  let tClamped = max(
    0,
    min(1, (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared)
  )
  let projected = CGPoint(x: start.x + (tClamped * dx), y: start.y + (tClamped * dy))
  return policyCanvasDistanceSquared(point, projected)
}

private func policyCanvasDistanceSquared(_ left: CGPoint, _ right: CGPoint) -> CGFloat {
  let dx = left.x - right.x
  let dy = left.y - right.y
  return (dx * dx) + (dy * dy)
}
