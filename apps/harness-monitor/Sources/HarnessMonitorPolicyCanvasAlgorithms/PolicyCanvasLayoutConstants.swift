import CoreGraphics

public enum PolicyCanvasLayout {
  public static let gridSize: CGFloat = 20
  public static let minimumZoom: CGFloat = 0.1
  public static let maximumZoom: CGFloat = 2.0
  public static let defaultZoom: CGFloat = 0.92
  public static let nodeWidth: CGFloat = 168
  public static let portDiameter: CGFloat = 18
  public static let portHitTestExtension: CGFloat = 10
  public static let portMarkerInset: CGFloat = portDiameter / 2 + 2
  public static let verticalPortMarkerSpacing: CGFloat = portDiameter * 1.5
  public static let defaultEdgeLineSpacing: CGFloat = 22.4
  public static let routeChannelStep: CGFloat = 5
  public static let minimumSidePortMarkerSpacing = max(
    defaultEdgeLineSpacing + routeChannelStep,
    verticalPortMarkerSpacing
  )
  public static let nodeMinimumHeight = ceil(
    (portMarkerInset * 2) + (minimumSidePortMarkerSpacing * 3)
  )
  public static let automaticLayoutNodeStepHeight: CGFloat = 160
  public static let nodeSize = CGSize(width: nodeWidth, height: nodeMinimumHeight)
  public static let groupCornerRadius: CGFloat = 8
  public static let nodeCornerRadius: CGFloat = 8
  /// Vertical breathing room kept between a node-distance measurement bar and any
  /// unrelated node body it would otherwise hug as it crosses the gap corridor.
  public static let nodeDistanceObstacleClearance: CGFloat = 24
  public static let edgeLabelHeight: CGFloat = 28
  public static let edgeLabelMaxWidth: CGFloat = 220
  public static let edgeLabelLaneSpacing: CGFloat = 46
  public static let edgeBusLaneSpacing: CGFloat = 38
  public static let edgeLabelNodeClearance: CGFloat = 24
  public static let edgeLabelHorizontalMargin: CGFloat = 14
  public static let edgePortTurnMinimumLead: CGFloat = 36
  public static let initialContentOrigin = CGPoint(x: 520, y: 480)
  public static let initialViewportInset: CGFloat = 220
  public static let initialViewportTopBias: CGFloat = 64
  public static let groupHorizontalPadding: CGFloat = 44
  public static let groupVerticalPadding: CGFloat = 52
  public static let minimumGroupSize = CGSize(width: 220, height: 180)
  public static let minimumCanvasSize = CGSize(width: 3_800, height: 3_000)
  public static let canvasTrailingPadding: CGFloat = 1_200
  public static let canvasBottomPadding: CGFloat = 1_200
  /// First center used when the user clicks a palette button. Subsequent
  /// clicks step away from this anchor by `paletteDropStep` so identical
  /// clicks don't pile on top of each other.
  public static let initialPaletteDropAnchor = CGPoint(x: 640, y: 620)
  /// Per-click advance offset for palette button drops. 40pt = 2x grid step
  /// so the next drop lands cleanly on the grid and stays clear of the prior
  /// node frame.
  public static let paletteDropStep: CGFloat = 40

  public static func nodeSize(for node: PolicyCanvasNode) -> CGSize {
    CGSize(
      width: nodeWidth,
      height: nodeHeight(requiredVerticalPortSlots: logicalVerticalPortSlots(for: node))
    )
  }

  public static func nodeSize(
    for node: PolicyCanvasNode,
    edges: [PolicyCanvasEdge]
  ) -> CGSize {
    CGSize(
      width: nodeWidth,
      height: nodeHeight(
        requiredVerticalPortSlots: requiredVerticalPortSlots(for: node, edges: edges))
    )
  }

  public static func nodeSizes(
    for nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> [String: CGSize] {
    guard !nodes.isEmpty else {
      return [:]
    }
    let baseSlots = Dictionary(
      uniqueKeysWithValues: nodes.map {
        ($0.id, logicalVerticalPortSlots(for: $0))
      }
    )
    let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    var inputTerminalsByNodeID: [String: Int] = [:]
    var outputTerminalsByNodeID: [String: Int] = [:]
    for edge in edges {
      if let source = nodesByID[edge.source.nodeID],
        edge.source.kind == .output,
        source.outputPorts.contains(where: { $0.id == edge.source.portID })
      {
        outputTerminalsByNodeID[source.id, default: 0] += 1
      }
      if let target = nodesByID[edge.target.nodeID],
        edge.target.kind == .input,
        target.inputPorts.contains(where: { $0.id == edge.target.portID })
      {
        inputTerminalsByNodeID[target.id, default: 0] += 1
      }
    }
    return Dictionary(
      uniqueKeysWithValues: nodes.map { node in
        let slots = max(
          baseSlots[node.id, default: 1],
          inputTerminalsByNodeID[node.id, default: 0],
          outputTerminalsByNodeID[node.id, default: 0]
        )
        return (
          node.id,
          CGSize(width: nodeWidth, height: nodeHeight(requiredVerticalPortSlots: slots))
        )
      }
    )
  }

  public static func nodeHeight(requiredVerticalPortSlots slots: Int) -> CGFloat {
    let requiredSlots = max(1, slots)
    let requiredHeight =
      (portMarkerInset * 2)
      + (minimumSidePortMarkerSpacing * CGFloat(max(0, requiredSlots - 1)))
    return max(nodeMinimumHeight, ceil(requiredHeight))
  }

  public static func requiredVerticalPortSlots(
    for node: PolicyCanvasNode,
    edges: [PolicyCanvasEdge] = []
  ) -> Int {
    let slots = logicalVerticalPortSlots(for: node)
    guard !edges.isEmpty else {
      return slots
    }
    var inputTerminals = 0
    var outputTerminals = 0
    for edge in edges {
      if edge.source.nodeID == node.id,
        edge.source.kind == .output,
        node.outputPorts.contains(where: { $0.id == edge.source.portID })
      {
        outputTerminals += 1
      }
      if edge.target.nodeID == node.id,
        edge.target.kind == .input,
        node.inputPorts.contains(where: { $0.id == edge.target.portID })
      {
        inputTerminals += 1
      }
    }
    return max(slots, inputTerminals, outputTerminals)
  }

  private static func logicalVerticalPortSlots(for node: PolicyCanvasNode) -> Int {
    max(1, node.inputPorts.count, node.outputPorts.count)
  }

  public static func portY(index: Int, count: Int) -> CGFloat {
    portY(index: index, count: count, nodeHeight: nodeSize.height)
  }

  public static func portY(index: Int, count: Int, nodeHeight: CGFloat) -> CGFloat {
    guard count > 1 else {
      return nodeHeight / 2
    }
    let available = max(0, nodeHeight - (portMarkerInset * 2))
    let step = min(verticalPortMarkerSpacing, available / CGFloat(count - 1))
    let span = step * CGFloat(count - 1)
    let top = min(
      max((nodeHeight - span) / 2, portMarkerInset),
      nodeHeight - portMarkerInset - span
    )
    return top + (CGFloat(index) * step)
  }

  public static func portX(index: Int, count: Int) -> CGFloat {
    portX(index: index, count: count, nodeWidth: nodeSize.width)
  }

  public static func portX(index: Int, count: Int, nodeWidth: CGFloat) -> CGFloat {
    guard count > 1 else {
      return nodeWidth / 2
    }
    let step = min(CGFloat(32), nodeWidth / CGFloat(count + 1))
    let leading = (nodeWidth - (step * CGFloat(count - 1))) / 2
    return leading + (CGFloat(index) * step)
  }
}

// Quantizes a coordinate to the layout grid so fanout sort keys don't flip
// between adjacent integer buckets when a port anchor drags sub-pixel.
// Sub-pixel jitter previously toggled the rounded int (e.g. 100.4 -> 100,
// 100.6 -> 101) and reordered fanout mid-drag.
public func policyCanvasFanoutBucketCoordinate(
  _ value: CGFloat,
  quantum: CGFloat = PolicyCanvasLayout.gridSize
) -> Int {
  let step = max(quantum, 1)
  return Int((value / step).rounded()) * Int(step)
}
