import HarnessMonitorKit
import SwiftUI

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
    if let node = nodes.reversed().first(where: { policyCanvasNodeFrame($0).contains(point) }) {
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
    case .port, nil:
      return nil
    }
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
    let radius = (PolicyCanvasLayout.portDiameter / 2) + PolicyCanvasLayout.portHitTestExtension
    for node in nodes.reversed() {
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
    }
    return nil
  }
}
