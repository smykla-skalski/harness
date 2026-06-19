// ELK endpoint-port types and geometry helpers extracted from
// PolicyCanvasElkLayoutEngine to satisfy the file-length limit.
import CoreGraphics
import Foundation

enum PolicyCanvasElkEndpointRole {
  case source
  case target
}

struct PolicyCanvasElkEndpointPort {
  let edgeID: String
  let role: PolicyCanvasElkEndpointRole
  let nodeID: String
  let nodeSize: CGSize
  let side: PolicyCanvasPortSide
  let index: Int
  let origin: CGPoint
  let portID: String
}

func elkEndpointPorts(
  edges: [PolicyCanvasEdge],
  nodeSizes: [String: CGSize]
) -> [PolicyCanvasElkEndpointPort] {
  struct PartialPort {
    let edgeID: String
    let role: PolicyCanvasElkEndpointRole
    let nodeID: String
    let side: PolicyCanvasPortSide
    let portID: String
  }

  var partials: [PartialPort] = []
  partials.reserveCapacity(edges.count * 2)
  for edge in edges.sorted(by: { $0.id < $1.id }) {
    partials.append(
      PartialPort(
        edgeID: edge.id,
        role: .source,
        nodeID: edge.source.nodeID,
        side: .trailing,
        portID: "\(edge.id)__source"
      )
    )
    partials.append(
      PartialPort(
        edgeID: edge.id,
        role: .target,
        nodeID: edge.target.nodeID,
        side: .leading,
        portID: "\(edge.id)__target"
      )
    )
  }

  let groups = Dictionary(grouping: partials) { "\($0.nodeID)|\($0.side.rawValue)" }
  var ports: [PolicyCanvasElkEndpointPort] = []
  ports.reserveCapacity(partials.count)
  for key in groups.keys.sorted() {
    let values = groups[key, default: []].sorted(by: { lhs, rhs in
      if lhs.edgeID == rhs.edgeID {
        return elkEndpointRoleRank(lhs.role) < elkEndpointRoleRank(rhs.role)
      }
      return lhs.edgeID < rhs.edgeID
    })
    guard let side = values.first?.side else {
      continue
    }
    let nodeSize = values.first.flatMap { nodeSizes[$0.nodeID] } ?? PolicyCanvasLayout.nodeSize
    let coordinates = policyCanvasPortMarkerCoordinates(
      count: values.count,
      base: policyCanvasSideExtent(side: side, size: nodeSize) / 2,
      spacing: policyCanvasMinimumPortMarkerSpacing(),
      extent: policyCanvasSideExtent(side: side, size: nodeSize),
      inset: policyCanvasPortMarkerInset()
    )
    for (index, value) in values.enumerated() {
      ports.append(
        PolicyCanvasElkEndpointPort(
          edgeID: value.edgeID,
          role: value.role,
          nodeID: value.nodeID,
          nodeSize: nodeSize,
          side: value.side,
          index: index,
          origin: elkPortOrigin(
            side: value.side,
            coordinate: coordinates[index],
            nodeSize: nodeSize
          ),
          portID: value.portID
        )
      )
    }
  }
  return ports.sorted { $0.portID < $1.portID }
}

func elkPortOrigin(
  side: PolicyCanvasPortSide,
  coordinate: CGFloat,
  nodeSize: CGSize
) -> CGPoint {
  let radius = PolicyCanvasLayout.portDiameter / 2
  switch side {
  case .leading:
    return CGPoint(x: 0, y: coordinate - radius)
  case .trailing:
    return CGPoint(x: nodeSize.width - radius, y: coordinate - radius)
  case .top:
    return CGPoint(x: coordinate - radius, y: -radius)
  case .bottom:
    return CGPoint(x: coordinate - radius, y: nodeSize.height - radius)
  }
}

func elkPortCenter(_ port: PolicyCanvasElkEndpointPort) -> CGPoint {
  let radius = PolicyCanvasLayout.portDiameter / 2
  switch port.side {
  case .leading:
    return CGPoint(x: 0, y: port.origin.y + radius)
  case .trailing:
    return CGPoint(x: port.nodeSize.width, y: port.origin.y + radius)
  case .top:
    return CGPoint(x: port.origin.x + radius, y: 0)
  case .bottom:
    return CGPoint(x: port.origin.x + radius, y: port.nodeSize.height)
  }
}

func elkAbsolutePortCenter(
  _ port: PolicyCanvasElkEndpointPort,
  nodePosition: CGPoint
) -> CGPoint {
  let center = elkPortCenter(port)
  return CGPoint(x: nodePosition.x + center.x, y: nodePosition.y + center.y)
}

func elkEndpointRoleRank(_ role: PolicyCanvasElkEndpointRole) -> Int {
  switch role {
  case .source: 0
  case .target: 1
  }
}

func elkRouteEndpointRole(_ role: PolicyCanvasElkEndpointRole)
  -> PolicyCanvasRouteEndpointRole
{
  switch role {
  case .source: .source
  case .target: .target
  }
}

func elkPortSideName(_ side: PolicyCanvasPortSide) -> String {
  switch side {
  case .leading: "WEST"
  case .trailing: "EAST"
  case .top: "NORTH"
  case .bottom: "SOUTH"
  }
}
