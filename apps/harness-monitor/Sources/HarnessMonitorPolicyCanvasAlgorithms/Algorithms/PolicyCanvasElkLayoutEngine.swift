import CoreGraphics
import ElkSwift
import Foundation

nonisolated(unsafe) private let policyCanvasElkRunner = PolicyCanvasElkRunner()
nonisolated(unsafe) private let policyCanvasElkLayoutCache = PolicyCanvasElkLayoutCache()
private let policyCanvasElkLayoutComputationLock = NSLock()

func policyCanvasElkLayoutResult(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode
) -> PolicyCanvasLayoutResult? {
  guard policyCanvasShouldUseElkLayout(mode: mode) else {
    return nil
  }
  return PolicyCanvasElkLayoutEngine(
    nodes: nodes,
    groups: groups,
    edges: edges,
    mode: mode
  ).layout()
}

private func policyCanvasShouldUseElkLayout(
  mode: PolicyCanvasAutomaticLayoutMode
) -> Bool {
  switch mode {
  case .initialLoad:
    return true
  case .explicitReflow(let preserveManualAnchors):
    return !preserveManualAnchors
  }
}

private struct PolicyCanvasElkLayoutEngine {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let mode: PolicyCanvasAutomaticLayoutMode

  func layout() -> PolicyCanvasLayoutResult? {
    let identity = elkIdentity()
    if let cached = policyCanvasElkLayoutCache.value(for: identity) {
      return cached
    }
    let nodeSizes = PolicyCanvasLayout.nodeSizes(for: nodes, edges: edges)
    let graph = policyCanvasLayoutGraph(nodes: nodes, groups: groups, edges: edges, mode: mode)
    let endpointPorts = elkEndpointPorts(edges: edges, nodeSizes: nodeSizes)
    let elkGraph = elkGraphJSON(endpointPorts: endpointPorts, nodeSizes: nodeSizes)
    policyCanvasElkLayoutComputationLock.lock()
    defer { policyCanvasElkLayoutComputationLock.unlock() }
    if let cached = policyCanvasElkLayoutCache.value(for: identity) {
      return cached
    }
    let result: [String: Any]
    do {
      result = try policyCanvasElkRunner.layout(graph: elkGraph, timeout: 1)
    } catch {
      return nil
    }
    guard let rawNodePositions = elkNodePositions(result), rawNodePositions.count == nodes.count
    else {
      return nil
    }
    let nodePositions = policyCanvasResolveNodeOverlaps(
      nodePositions: rawNodePositions,
      nodeSizes: nodeSizes
    )
    guard
      let routes = elkRoutes(result, nodePositions: nodePositions, endpointPorts: endpointPorts),
      routes.count == edges.count
    else {
      return nil
    }
    let normalizedGroups = PolicyCanvasLayeredLayoutEngine(mode: mode).normalizedGroups(for: graph)
    let layoutGroupIDByNodeID = Dictionary(
      uniqueKeysWithValues: normalizedGroups.flatMap { group in
        group.nodeIDs.map { ($0, group.layoutID) }
      }
    )
    let groupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
      normalizedGroups: normalizedGroups,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      nodePositions: nodePositions,
      nodeSizes: nodeSizes
    )
    let groupFrames = actualGroupFrames(
      normalizedGroups: normalizedGroups,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    let groupRanks = elkGroupRanks(
      normalizedGroups: normalizedGroups,
      nodePositions: nodePositions
    )
    let metrics = policyCanvasElkLayoutMetrics(
      graph: graph,
      nodePositions: nodePositions,
      nodeSizes: nodeSizes,
      groupRanks: groupRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      autoPlacedNodeIDs: Set(nodes.map(\.id)),
      metrics: metrics,
      routingHints: nil,
      precomputedRoutes: PolicyCanvasPrecomputedRouteSet(
        identity: identity,
        routes: routes
      )
    )
    .cachingElkLayoutResult(identity: identity)
  }

  private func elkGraphJSON(
    endpointPorts: [PolicyCanvasElkEndpointPort],
    nodeSizes: [String: CGSize]
  ) -> [String: Any] {
    let portsByNodeID = Dictionary(grouping: endpointPorts, by: \.nodeID)
    return [
      "id": "policy-canvas",
      "layoutOptions": policyCanvasElkLayoutOptions(),
      "children": nodes.map { node in
        let nodeSize = nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node)
        return [
          "id": node.id,
          "width": Double(nodeSize.width),
          "height": Double(nodeSize.height),
          "layoutOptions": [
            "org.eclipse.elk.portConstraints": "FIXED_POS"
          ],
          "ports": (portsByNodeID[node.id] ?? []).map(elkPortJSON),
        ] as [String: Any]
      },
      "edges": edges.map { edge in
        [
          "id": edge.id,
          "sources": [endpointPorts.first { $0.edgeID == edge.id && $0.role == .source }?.portID]
            .compactMap(\.self),
          "targets": [endpointPorts.first { $0.edgeID == edge.id && $0.role == .target }?.portID]
            .compactMap(\.self),
        ] as [String: Any]
      },
    ]
  }

  private func elkPortJSON(_ port: PolicyCanvasElkEndpointPort) -> [String: Any] {
    [
      "id": port.portID,
      "width": Double(PolicyCanvasLayout.portDiameter),
      "height": Double(PolicyCanvasLayout.portDiameter),
      "x": Double(port.origin.x),
      "y": Double(port.origin.y),
      "layoutOptions": [
        "org.eclipse.elk.port.side": elkPortSideName(port.side),
        "org.eclipse.elk.port.index": port.index,
      ],
    ]
  }

  private func elkNodePositions(_ result: [String: Any]) -> [String: CGPoint]? {
    guard let children = result["children"] as? [[String: Any]] else {
      return nil
    }
    var positions: [String: CGPoint] = [:]
    positions.reserveCapacity(children.count)
    for child in children {
      guard let id = child["id"] as? String,
        let x = elkDouble(child["x"]),
        let y = elkDouble(child["y"])
      else {
        return nil
      }
      positions[id] = snappedLayoutPoint(CGPoint(x: x, y: y))
    }
    return positions
  }

  private func elkRoutes(
    _ result: [String: Any],
    nodePositions: [String: CGPoint],
    endpointPorts: [PolicyCanvasElkEndpointPort]
  ) -> [String: PolicyCanvasEdgeRoute]? {
    guard let edgeResults = result["edges"] as? [[String: Any]] else {
      return nil
    }
    let portsByKey = Dictionary(
      uniqueKeysWithValues: endpointPorts.map { port in
        (
          PolicyCanvasRouteTerminalKey(edgeID: port.edgeID, role: elkRouteEndpointRole(port.role)),
          port
        )
      }
    )
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(edgeResults.count)
    for edgeResult in edgeResults {
      guard let id = edgeResult["id"] as? String,
        let sections = edgeResult["sections"] as? [[String: Any]],
        let firstSection = sections.first,
        let points = elkRoutePoints(section: firstSection),
        let sourcePort = portsByKey[PolicyCanvasRouteTerminalKey(edgeID: id, role: .source)],
        let targetPort = portsByKey[PolicyCanvasRouteTerminalKey(edgeID: id, role: .target)],
        let sourcePosition = nodePositions[sourcePort.nodeID],
        let targetPosition = nodePositions[targetPort.nodeID]
      else {
        return nil
      }
      let aligned = elkRoutePointsAligningTerminals(
        points,
        sourceTerminal: elkAbsolutePortCenter(sourcePort, nodePosition: sourcePosition),
        sourceSide: sourcePort.side,
        targetTerminal: elkAbsolutePortCenter(targetPort, nodePosition: targetPosition),
        targetSide: targetPort.side
      )
      let compressed = policyCanvasCompressPreservingTerminalStubs(aligned)
      let route = PolicyCanvasEdgeRoute(
        points: compressed,
        labelPosition: PolicyCanvasEdgeRoute(
          points: compressed,
          labelPosition: compressed.first ?? .zero
        ).arcLengthMidpoint
      )
      routes[id] = route
    }
    return routes
  }

  private func elkRoutePoints(section: [String: Any]) -> [CGPoint]? {
    guard let start = elkPoint(section["startPoint"]),
      let end = elkPoint(section["endPoint"])
    else {
      return nil
    }
    let bends = (section["bendPoints"] as? [[String: Any]] ?? []).compactMap(elkPoint)
    guard bends.count == (section["bendPoints"] as? [[String: Any]] ?? []).count else {
      return nil
    }
    return [start] + bends + [end]
  }

  private func elkRoutePointsAligningTerminals(
    _ points: [CGPoint],
    sourceTerminal: CGPoint,
    sourceSide: PolicyCanvasPortSide,
    targetTerminal: CGPoint,
    targetSide: PolicyCanvasPortSide
  ) -> [CGPoint] {
    guard !points.isEmpty else {
      return points
    }
    guard points.count > 2 else {
      return elkTwoPointRoute(
        sourceTerminal: sourceTerminal,
        sourceSide: sourceSide,
        targetTerminal: targetTerminal,
        targetSide: targetSide
      )
    }
    var snapped = points
    snapped[snapped.startIndex] = sourceTerminal
    let sourceLeadIndex = snapped.index(after: snapped.startIndex)
    snapped[sourceLeadIndex] = elkRoutePoint(
      snapped[sourceLeadIndex],
      alignedTo: sourceTerminal,
      side: sourceSide
    )
    let lastIndex = snapped.index(before: snapped.endIndex)
    let targetLeadIndex = snapped.index(before: lastIndex)
    snapped[targetLeadIndex] = elkRoutePoint(
      snapped[targetLeadIndex],
      alignedTo: targetTerminal,
      side: targetSide
    )
    snapped[lastIndex] = targetTerminal
    return snapped
  }

  private func elkTwoPointRoute(
    sourceTerminal: CGPoint,
    sourceSide: PolicyCanvasPortSide,
    targetTerminal: CGPoint,
    targetSide: PolicyCanvasPortSide
  ) -> [CGPoint] {
    let sourceLead = policyCanvasPortLeadPoint(sourceTerminal, side: sourceSide)
    let targetLead = policyCanvasPortLeadPoint(targetTerminal, side: targetSide)
    var points = [sourceTerminal, sourceLead]
    if abs(sourceLead.x - targetLead.x) > 0.001,
      abs(sourceLead.y - targetLead.y) > 0.001
    {
      points.append(CGPoint(x: targetLead.x, y: sourceLead.y))
    }
    points.append(targetLead)
    points.append(targetTerminal)
    return points
  }

  private func elkRoutePoint(
    _ point: CGPoint,
    alignedTo terminal: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGPoint {
    switch side {
    case .leading, .trailing:
      CGPoint(x: point.x, y: terminal.y)
    case .top, .bottom:
      CGPoint(x: terminal.x, y: point.y)
    }
  }

  private func actualGroupFrames(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupFramesByLayoutID: [String: CGRect]
  ) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for group in normalizedGroups {
      guard let actualGroupID = group.actualGroupID,
        let frame = groupFramesByLayoutID[group.layoutID]
      else {
        continue
      }
      frames[actualGroupID] = frame
    }
    return frames
  }

  private func elkGroupRanks(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    nodePositions: [String: CGPoint]
  ) -> [String: Int] {
    let ordered =
      normalizedGroups
      .map { group -> (id: String, x: CGFloat) in
        let minX = group.nodeIDs.compactMap { nodePositions[$0]?.x }.min() ?? 0
        return (group.layoutID, minX)
      }
      .sorted {
        if $0.x == $1.x {
          return $0.id < $1.id
        }
        return $0.x < $1.x
      }
    return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
  }

  private func elkIdentity() -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037

    func elkCombine(_ value: String) {
      for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0xff
      hash &*= 1_099_511_628_211
    }

    elkCombine("elk-swift-grid-ports-1")
    for node in nodes {
      elkCombine(node.id)
      elkCombine(node.groupID ?? "")
      let nodeSize = PolicyCanvasLayout.nodeSize(for: node, edges: edges)
      elkCombine("\(Int(nodeSize.width.rounded()))x\(Int(nodeSize.height.rounded()))")
    }
    for edge in edges {
      elkCombine(edge.id)
      elkCombine(edge.source.nodeID)
      elkCombine(edge.source.portID)
      elkCombine(edge.target.nodeID)
      elkCombine(edge.target.portID)
      elkCombine(edge.label)
      elkCombine(edge.source.side?.rawValue ?? "")
      elkCombine(edge.target.side?.rawValue ?? "")
    }
    return "elk:\(String(hash, radix: 16))"
  }
}

private final class PolicyCanvasElkLayoutCache {
  private let lock = NSLock()
  private var order: [String] = []
  private var values: [String: PolicyCanvasLayoutResult] = [:]
  private let capacity = 8

  func value(for identity: String) -> PolicyCanvasLayoutResult? {
    lock.lock()
    defer { lock.unlock() }
    return values[identity]
  }

  func store(_ result: PolicyCanvasLayoutResult, for identity: String) {
    lock.lock()
    defer { lock.unlock() }
    if values[identity] == nil {
      order.append(identity)
    }
    values[identity] = result
    while order.count > capacity {
      values.removeValue(forKey: order.removeFirst())
    }
  }
}

extension PolicyCanvasLayoutResult {
  fileprivate func cachingElkLayoutResult(identity: String) -> Self {
    policyCanvasElkLayoutCache.store(self, for: identity)
    return self
  }
}

private final class PolicyCanvasElkRunner {
  private let elk = ELK()
  private let lock = NSLock()

  func layout(graph: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    return try elk.layout(graph: graph, timeout: timeout)
  }
}

private func policyCanvasElkLayoutOptions() -> [String: Any] {
  let edgeSpacing = String(Int(PolicyCanvasLayout.defaultEdgeLineSpacing.rounded()))
  return [
    "elk.algorithm": "layered",
    "elk.direction": "RIGHT",
    "elk.edgeRouting": "ORTHOGONAL",
    "elk.randomSeed": "1",
    "elk.layered.thoroughness": "2",
    "elk.layered.highDegreeNodes.treatment": "true",
    "elk.layered.highDegreeNodes.threshold": "8",
    "elk.spacing.nodeNode": "80",
    "elk.layered.spacing.nodeNodeBetweenLayers": "120",
    "elk.spacing.edgeNode": "40",
    "elk.spacing.edgeEdge": edgeSpacing,
  ]
}

private enum PolicyCanvasElkEndpointRole {
  case source
  case target
}

private struct PolicyCanvasElkEndpointPort {
  let edgeID: String
  let role: PolicyCanvasElkEndpointRole
  let nodeID: String
  let nodeSize: CGSize
  let side: PolicyCanvasPortSide
  let index: Int
  let origin: CGPoint
  let portID: String
}

private func elkEndpointPorts(
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

private func elkPortOrigin(
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

private func elkPortCenter(_ port: PolicyCanvasElkEndpointPort) -> CGPoint {
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

private func elkAbsolutePortCenter(
  _ port: PolicyCanvasElkEndpointPort,
  nodePosition: CGPoint
) -> CGPoint {
  let center = elkPortCenter(port)
  return CGPoint(x: nodePosition.x + center.x, y: nodePosition.y + center.y)
}

private func elkEndpointRoleRank(_ role: PolicyCanvasElkEndpointRole) -> Int {
  switch role {
  case .source: 0
  case .target: 1
  }
}

private func elkRouteEndpointRole(_ role: PolicyCanvasElkEndpointRole)
  -> PolicyCanvasRouteEndpointRole
{
  switch role {
  case .source: .source
  case .target: .target
  }
}

private func elkPortSideName(_ side: PolicyCanvasPortSide) -> String {
  switch side {
  case .leading: "WEST"
  case .trailing: "EAST"
  case .top: "NORTH"
  case .bottom: "SOUTH"
  }
}

private func elkDouble(_ value: Any?) -> CGFloat? {
  if let double = value as? Double {
    return CGFloat(double)
  }
  if let int = value as? Int {
    return CGFloat(int)
  }
  if let number = value as? NSNumber {
    return CGFloat(truncating: number)
  }
  if let string = value as? String, let double = Double(string) {
    return CGFloat(double)
  }
  return nil
}

private func elkPoint(_ value: Any?) -> CGPoint? {
  guard let dictionary = value as? [String: Any],
    let x = elkDouble(dictionary["x"]),
    let y = elkDouble(dictionary["y"])
  else {
    return nil
  }
  return snappedLayoutPoint(CGPoint(x: x, y: y))
}

private func policyCanvasElkLayoutMetrics(
  graph: PolicyCanvasLayoutGraph,
  nodePositions: [String: CGPoint],
  nodeSizes: [String: CGSize],
  groupRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> PolicyCanvasLayoutMetrics {
  let nodeCenters = Dictionary(
    uniqueKeysWithValues: graph.nodes.compactMap { node -> (String, CGPoint)? in
      guard let position = nodePositions[node.id] else {
        return nil
      }
      let frame = CGRect(origin: position, size: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize)
      return (node.id, CGPoint(x: frame.midX, y: frame.midY))
    }
  )
  var flowDirectionViolations = 0
  var edgeLengths: [Double] = []
  edgeLengths.reserveCapacity(graph.edges.count)
  var crossGroupOrderViolations = 0
  for edge in graph.edges {
    if let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
      let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
      sourceGroupID != targetGroupID,
      let sourceRank = groupRanks[sourceGroupID],
      let targetRank = groupRanks[targetGroupID],
      sourceRank > targetRank
    {
      crossGroupOrderViolations += 1
    }
    guard
      let sourceCenter = nodeCenters[edge.sourceNodeID],
      let targetCenter = nodeCenters[edge.targetNodeID]
    else {
      continue
    }
    if targetCenter.x + 1 < sourceCenter.x {
      flowDirectionViolations += 1
    }
    edgeLengths.append(
      hypot(
        Double(targetCenter.x - sourceCenter.x),
        Double(targetCenter.y - sourceCenter.y)
      )
    )
  }
  let averageEdgeLength =
    edgeLengths.isEmpty ? 0 : edgeLengths.reduce(0, +) / Double(edgeLengths.count)
  let edgeLengthVariance =
    edgeLengths.isEmpty
    ? 0
    : edgeLengths.reduce(into: 0) { partial, length in
      let delta = length - averageEdgeLength
      partial += delta * delta
    } / Double(edgeLengths.count)
  let normalizedLengthVariance =
    averageEdgeLength > 0
    ? edgeLengthVariance / max(1.0, averageEdgeLength * averageEdgeLength)
    : 0
  let readabilityScore = max(
    0,
    1_000
      - Double(flowDirectionViolations * 80)
      - Double(crossGroupOrderViolations * 120)
      - (normalizedLengthVariance * 100)
  )
  return PolicyCanvasLayoutMetrics(
    macroLayerCount: Set(groupRanks.values).count,
    crossGroupOrderViolations: crossGroupOrderViolations,
    anchoredNodeCount: graph.nodes.reduce(into: 0) { count, node in
      if node.anchor != nil {
        count += 1
      }
    },
    edgeCrossingCount: 0,
    flowDirectionViolationCount: flowDirectionViolations,
    averageEdgeLength: averageEdgeLength,
    edgeLengthVariance: edgeLengthVariance,
    readabilityScore: readabilityScore
  )
}
