import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

struct PolicyCanvasNodeLookup {
  private struct Cell: Hashable {
    let x: Int
    let y: Int
  }

  private static let cellSize: CGFloat = 256

  private let nodesByID: [String: PolicyCanvasNode]
  private let framesByID: [String: CGRect]
  private let buckets: [Cell: [String]]

  init(nodes: [PolicyCanvasNode]) {
    nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let framesByID = Dictionary(
      uniqueKeysWithValues: nodes.map {
        ($0.id, CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize))
      }
    )
    self.framesByID = framesByID
    var buckets: [Cell: [String]] = [:]
    for (id, frame) in framesByID {
      for cell in Self.cells(intersecting: frame) {
        buckets[cell, default: []].append(id)
      }
    }
    self.buckets = buckets
  }

  func node(id: String) -> PolicyCanvasNode? {
    nodesByID[id]
  }

  func containsNode(except excludedID: String, intersecting rect: CGRect) -> Bool {
    var visited: Set<String> = []
    for cell in Self.cells(intersecting: rect) {
      for id in buckets[cell] ?? [] where id != excludedID && visited.insert(id).inserted {
        if framesByID[id]?.intersects(rect) == true {
          return true
        }
      }
    }
    return false
  }

  private static func cells(intersecting rect: CGRect) -> [Cell] {
    guard !rect.isNull, !rect.isEmpty else {
      return []
    }
    let minX = Int(floor(rect.minX / cellSize))
    let maxX = Int(floor((rect.maxX - 1) / cellSize))
    let minY = Int(floor(rect.minY / cellSize))
    let maxY = Int(floor((rect.maxY - 1) / cellSize))
    var cells: [Cell] = []
    cells.reserveCapacity(max(1, (maxX - minX + 1) * (maxY - minY + 1)))
    for x in minX...maxX {
      for y in minY...maxY {
        cells.append(Cell(x: x, y: y))
      }
    }
    return cells
  }
}

struct PolicyCanvasDocumentLayoutLookup {
  private let nodeLayoutsByID: [String: TaskBoardPolicyPipelineNodeLayout]

  init(layout: TaskBoardPolicyPipelineLayout) {
    var nodeLayoutsByID: [String: TaskBoardPolicyPipelineNodeLayout] = [:]
    for node in layout.nodes where nodeLayoutsByID[node.nodeId.rawValue] == nil {
      nodeLayoutsByID[node.nodeId.rawValue] = node
    }
    self.nodeLayoutsByID = nodeLayoutsByID
  }

  func nodeLayout(
    for nodeID: String
  ) -> (position: TaskBoardPolicyCanvasPoint, source: PolicyGraphNodeLayoutSource?)? {
    guard let node = nodeLayoutsByID[nodeID] else {
      return nil
    }
    return (
      position: TaskBoardPolicyCanvasPoint(x: Double(node.x), y: Double(node.y)),
      source: node.source
    )
  }
}

func synthesizedGroupFrame(
  offset: Int,
  group: TaskBoardPolicyPipelineGroup,
  nodes: [PolicyCanvasNode]
) -> CGRect {
  let memberIDs = Set(group.nodeIds.map(\.rawValue))
  let members = nodes.filter { node in
    node.groupID == group.id.rawValue || memberIDs.contains(node.id)
  }
  guard !members.isEmpty else {
    return CGRect(x: 72 + CGFloat(offset * 280), y: 72, width: 248, height: 220)
  }
  let bounds = members.reduce(CGRect.null) { partial, node in
    partial.union(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
  }
  return policyCanvasGroupFrame(containing: bounds)
}

extension TaskBoardPolicyPipelineLayout {
  func nodeLayout(
    for nodeID: String
  ) -> (position: TaskBoardPolicyCanvasPoint, source: PolicyGraphNodeLayoutSource?)? {
    guard let node = nodes.first(where: { $0.nodeId.rawValue == nodeID }) else {
      return nil
    }
    return (
      position: TaskBoardPolicyCanvasPoint(x: Double(node.x), y: Double(node.y)),
      source: node.source
    )
  }
}

extension TaskBoardPolicyCanvasRect {
  var isEmpty: Bool {
    width <= 0 || height <= 0
  }
}

func taskBoardPolicyNodeKind(
  for kind: PolicyCanvasNodeKind
) -> PolicyGraphNodeKind {
  kind.defaultPolicyKind
}

func policyCanvasEdgeLabel(_ edge: TaskBoardPolicyPipelineEdge) -> String {
  if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines),
    !label.isEmpty
  {
    let normalized = policyCanvasNormalizedEdgeLabel(label)
    if !policyCanvasIsGenericEdgeLabel(normalized) {
      return normalized
    }
  }
  if let branchLabel = policyCanvasConditionalBranchLabel(
    fromPort: edge.fromPort.rawValue,
    condition: edge.condition.condition
  ) {
    return branchLabel
  }
  if edge.condition.condition != "always" {
    return edge.condition.condition.replacingOccurrences(of: "_", with: " ")
  }
  let fallback = policyCanvasNormalizedEdgeLabel(edge.fromPort.rawValue)
  return policyCanvasIsGenericEdgeLabel(fallback) ? "" : fallback
}

private func policyCanvasNormalizedEdgeLabel(_ label: String) -> String {
  label
    .replacingOccurrences(of: "_", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func policyCanvasConditionalBranchLabel(
  fromPort: String,
  condition: String
) -> String? {
  switch policyCanvasNormalizedEdgeLabel(fromPort).lowercased() {
  case "then", "true":
    return "then"
  case "else", "false":
    return "else"
  default:
    break
  }
  switch condition.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
  case "condition_true":
    return "then"
  case "condition_false":
    return "else"
  default:
    return nil
  }
}

private func policyCanvasIsGenericEdgeLabel(_ label: String) -> Bool {
  switch label.lowercased() {
  case "", "in", "input", "policy", "input policy":
    true
  default:
    false
  }
}

func policyCanvasAssignPreferredPortSides(
  source: inout PolicyCanvasPortEndpoint,
  target: inout PolicyCanvasPortEndpoint,
  nodes: [PolicyCanvasNode]
) {
  policyCanvasAssignPreferredPortSides(
    source: &source,
    target: &target,
    nodeLookup: PolicyCanvasNodeLookup(nodes: nodes)
  )
}

func policyCanvasAssignPreferredPortSides(
  source: inout PolicyCanvasPortEndpoint,
  target: inout PolicyCanvasPortEndpoint,
  nodeLookup: PolicyCanvasNodeLookup
) {
  guard
    let sourceNode = nodeLookup.node(id: source.nodeID),
    let targetNode = nodeLookup.node(id: target.nodeID),
    sourceNode.groupID == targetNode.groupID
  else {
    return
  }
  let horizontalDelta = abs(sourceNode.position.x - targetNode.position.x)
  let verticalDelta = abs(sourceNode.position.y - targetNode.position.y)
  if horizontalDelta >= PolicyCanvasLayout.nodeSize.width {
    if sourceNode.position.x < targetNode.position.x {
      source.side = .trailing
      target.side = .leading
    } else {
      source.side = .leading
      target.side = .trailing
    }
    policyCanvasUnblockTargetPortSide(
      target: &target,
      targetNode: targetNode,
      sourceNode: sourceNode,
      nodeLookup: nodeLookup
    )
    return
  }
  guard verticalDelta > horizontalDelta,
    verticalDelta >= PolicyCanvasLayout.nodeSize.height
  else {
    return
  }
  if sourceNode.position.y < targetNode.position.y {
    source.side = .bottom
    target.side = .top
  } else {
    source.side = .top
    target.side = .bottom
  }
  policyCanvasUnblockTargetPortSide(
    target: &target,
    targetNode: targetNode,
    sourceNode: sourceNode,
    nodeLookup: nodeLookup
  )
}

/// Steer the target off a port side that another node sits flush against.
///
/// The router escapes a port by stepping `edgePortTurnMinimumLead` straight out
/// before it turns. When a foreign node sits flush against the chosen side, that
/// lead point lands inside the neighbor; the router then reads the neighbor as an
/// endpoint, drops it from the obstacle set, and the wire cuts straight through
/// its body. So when the geometrically preferred target side is blocked this way,
/// switch to the perpendicular side that still faces the source - but only if
/// that side is itself clear, so the fallback never trades one body hit for
/// another.
private func policyCanvasUnblockTargetPortSide(
  target: inout PolicyCanvasPortEndpoint,
  targetNode: PolicyCanvasNode,
  sourceNode: PolicyCanvasNode,
  nodes: [PolicyCanvasNode]
) {
  policyCanvasUnblockTargetPortSide(
    target: &target,
    targetNode: targetNode,
    sourceNode: sourceNode,
    nodeLookup: PolicyCanvasNodeLookup(nodes: nodes)
  )
}

private func policyCanvasUnblockTargetPortSide(
  target: inout PolicyCanvasPortEndpoint,
  targetNode: PolicyCanvasNode,
  sourceNode: PolicyCanvasNode,
  nodeLookup: PolicyCanvasNodeLookup
) {
  guard let side = target.side,
    policyCanvasPortSideIsBlocked(node: targetNode, side: side, nodeLookup: nodeLookup),
    let alternative = policyCanvasPerpendicularFacingSide(
      from: side, node: targetNode, toward: sourceNode
    ),
    !policyCanvasPortSideIsBlocked(node: targetNode, side: alternative, nodeLookup: nodeLookup)
  else {
    return
  }
  target.side = alternative
}

private func policyCanvasPortSideIsBlocked(
  node: PolicyCanvasNode,
  side: PolicyCanvasPortSide,
  nodes: [PolicyCanvasNode]
) -> Bool {
  policyCanvasPortSideIsBlocked(
    node: node,
    side: side,
    nodeLookup: PolicyCanvasNodeLookup(nodes: nodes)
  )
}

private func policyCanvasPortSideIsBlocked(
  node: PolicyCanvasNode,
  side: PolicyCanvasPortSide,
  nodeLookup: PolicyCanvasNodeLookup
) -> Bool {
  let frame = CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  // One point past the lead so a neighbor sitting exactly one lead away - whose
  // edge the lead point lands on, dropping it from the obstacle set - still
  // counts as blocking.
  let reach = PolicyCanvasLayout.edgePortTurnMinimumLead + 1
  let corridor: CGRect
  switch side {
  case .leading:
    corridor = CGRect(x: frame.minX - reach, y: frame.minY, width: reach, height: frame.height)
  case .trailing:
    corridor = CGRect(x: frame.maxX, y: frame.minY, width: reach, height: frame.height)
  case .top:
    corridor = CGRect(x: frame.minX, y: frame.minY - reach, width: frame.width, height: reach)
  case .bottom:
    corridor = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: reach)
  }
  return nodeLookup.containsNode(except: node.id, intersecting: corridor)
}

/// The perpendicular side that still faces the source, or nil when the source is
/// not offset by a full node on the perpendicular axis (no side genuinely faces
/// it there, so a flip would only point the wire away from its origin).
private func policyCanvasPerpendicularFacingSide(
  from side: PolicyCanvasPortSide,
  node: PolicyCanvasNode,
  toward other: PolicyCanvasNode
) -> PolicyCanvasPortSide? {
  switch side {
  case .leading, .trailing:
    if other.position.y + PolicyCanvasLayout.nodeSize.height <= node.position.y {
      return .top
    }
    if other.position.y >= node.position.y + PolicyCanvasLayout.nodeSize.height {
      return .bottom
    }
    return nil
  case .top, .bottom:
    if other.position.x + PolicyCanvasLayout.nodeSize.width <= node.position.x {
      return .leading
    }
    if other.position.x >= node.position.x + PolicyCanvasLayout.nodeSize.width {
      return .trailing
    }
    return nil
  }
}

func policyCanvasAssignTrustedLayoutSources(
  _ nodes: [PolicyCanvasNode]
) -> [PolicyCanvasNode] {
  var trustedNodes = nodes
  for index in trustedNodes.indices where trustedNodes[index].layoutSource == nil {
    trustedNodes[index].layoutSource = .manual
  }
  return trustedNodes
}
