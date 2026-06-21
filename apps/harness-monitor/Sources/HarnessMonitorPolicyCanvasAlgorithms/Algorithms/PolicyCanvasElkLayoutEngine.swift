import CoreGraphics
import ElkSwift
import Foundation

nonisolated(unsafe) private let policyCanvasElkRunner = PolicyCanvasElkRunner()
nonisolated(unsafe) let policyCanvasElkLayoutCache = PolicyCanvasElkLayoutCache()
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
    let basePositions = policyCanvasResolveNodeOverlaps(
      nodePositions: rawNodePositions,
      nodeSizes: nodeSizes
    )
    let normalizedGroups = PolicyCanvasLayeredLayoutEngine(mode: mode).normalizedGroups(for: graph)
    let layoutGroupIDByNodeID = Dictionary(
      uniqueKeysWithValues: normalizedGroups.flatMap { group in
        group.nodeIDs.map { ($0, group.layoutID) }
      }
    )
    // ELK lays out a flat node list, so a group frame - the bounding box of its
    // members - can swallow a foreign node and drop it under that group's title
    // band. The title then renders over the node and any wire reaching the node's
    // port crosses the title. The automatic-layout paths already clear this; run
    // the same clearance here so ELK layouts keep foreign nodes out of title
    // bands. Done before routing so the routes track the cleared positions.
    let prelimGroupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
      normalizedGroups: normalizedGroups,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      nodePositions: basePositions,
      nodeSizes: nodeSizes
    )
    let nodePositions = policyCanvasResolveNodeAndForeignTitleOverlaps(
      nodePositions: basePositions,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      groupTitleFramesByID: prelimGroupFramesByLayoutID.mapValues {
        policyCanvasGroupTitleFrame(in: $0)
      },
      nodeSizes: nodeSizes
    )
    guard
      let routes = elkRoutes(result, nodePositions: nodePositions, endpointPorts: endpointPorts),
      routes.count == edges.count
    else {
      return nil
    }
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
    let minimumLead = PolicyCanvasLayout.defaultEdgeLineSpacing
    func leadDistance(_ delta: CGFloat) -> CGFloat {
      max(minimumLead, PolicyCanvasLayout.routeGridRound(abs(delta)))
    }
    switch side {
    case .leading, .trailing:
      let direction: CGFloat = side == .trailing ? 1 : -1
      let delta = (point.x - terminal.x) * direction
      return CGPoint(
        x: terminal.x + (direction * leadDistance(delta)),
        y: terminal.y
      )
    case .top, .bottom:
      let direction: CGFloat = side == .bottom ? 1 : -1
      let delta = (point.y - terminal.y) * direction
      return CGPoint(
        x: terminal.x,
        y: terminal.y + (direction * leadDistance(delta))
      )
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

    elkCombine("elk-swift-grid-ports-2")
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
