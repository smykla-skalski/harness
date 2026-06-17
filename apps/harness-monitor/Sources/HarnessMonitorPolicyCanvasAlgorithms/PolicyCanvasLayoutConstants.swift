import CoreGraphics

public enum PolicyCanvasLayout {
  public static let gridSize: CGFloat = 20
  public static let minimumZoom: CGFloat = 0.1
  public static let maximumZoom: CGFloat = 2.0
  public static let defaultZoom: CGFloat = 0.92
  public static let nodeWidth: CGFloat = 180
  public static let portDiameter: CGFloat = 20
  public static let portHitTestExtension: CGFloat = 10
  public static let routeChannelStep: CGFloat = gridSize
  public static let portMarkerInset: CGFloat = gridSize
  public static let verticalPortMarkerSpacing: CGFloat = 20
  public static let defaultEdgeLineSpacing: CGFloat = verticalPortMarkerSpacing
  public static let minimumSidePortMarkerSpacing = verticalPortMarkerSpacing
  public static let nodeMinimumHeight = gridSize * 4
  public static let automaticLayoutNodeStepHeight: CGFloat = 160
  public static let nodeSize = CGSize(width: nodeWidth, height: nodeMinimumHeight)
  public static let groupCornerRadius: CGFloat = 8
  public static let nodeCornerRadius: CGFloat = 8
  /// Vertical breathing room kept between a node-distance measurement bar and any
  /// unrelated node body it would otherwise hug as it crosses the gap corridor.
  public static let nodeDistanceObstacleClearance: CGFloat = 25
  public static let edgeLabelHeight: CGFloat = 30
  public static let edgeLabelMaxWidth: CGFloat = 220
  public static let edgeLabelLaneSpacing: CGFloat = 40
  public static let edgeBusLaneSpacing: CGFloat = 40
  public static let edgeLabelNodeClearance: CGFloat = 25
  public static let edgeLabelHorizontalMargin: CGFloat = 15
  public static let edgePortTurnMinimumLead: CGFloat = 40
  public static let initialContentOrigin = CGPoint(x: 520, y: 480)
  public static let initialViewportInset: CGFloat = 220
  public static let initialViewportTopBias: CGFloat = 64
  public static let groupHorizontalPadding: CGFloat = 40
  public static let groupVerticalPadding: CGFloat = 60
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
    let portSpan = minimumSidePortMarkerSpacing * CGFloat(max(0, requiredSlots - 1))
    let requiredHeight =
      (portMarkerInset * 2)
      + portSpan
    var height = max(nodeMinimumHeight, routeGridCeil(requiredHeight))
    // Centered side-port stacks only land on the 20 pt route grid when the
    // remaining top/bottom margin is an even number of grid steps. Otherwise an
    // edge between differently-sized nodes must contain a 10 pt jog somewhere.
    while !routeGridAligned(height - portSpan, quantum: gridSize * 2) {
      height += gridSize
    }
    return height
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
      return routeGridRound(nodeHeight / 2)
    }
    let step = minimumSidePortMarkerSpacing
    let span = step * CGFloat(count - 1)
    let top = routeGridRound((nodeHeight - span) / 2)
    return routeGridRound(top + (CGFloat(index) * step))
  }

  public static func portX(index: Int, count: Int) -> CGFloat {
    portX(index: index, count: count, nodeWidth: nodeSize.width)
  }

  public static func portX(index: Int, count: Int, nodeWidth: CGFloat) -> CGFloat {
    guard count > 1 else {
      return routeGridRound(nodeWidth / 2)
    }
    let available = max(0, nodeWidth - (portMarkerInset * 2))
    let step = max(
      routeChannelStep,
      routeGridFloor(min(verticalPortMarkerSpacing, available / CGFloat(count - 1)))
    )
    let span = step * CGFloat(count - 1)
    let leading = clampedRouteGridRound(
      (nodeWidth - span) / 2,
      lowerBound: portMarkerInset,
      upperBound: nodeWidth - portMarkerInset - span
    )
    return routeGridRound(leading + (CGFloat(index) * step))
  }

  public static func routeGridFloor(_ value: CGFloat) -> CGFloat {
    let step = max(routeChannelStep, 1)
    return floor(value / step) * step
  }

  public static func routeGridRound(_ value: CGFloat) -> CGFloat {
    let step = max(routeChannelStep, 1)
    return (value / step).rounded() * step
  }

  public static func routeGridCeil(_ value: CGFloat) -> CGFloat {
    let step = max(routeChannelStep, 1)
    return ceil(value / step) * step
  }

  public static func clampedRouteGridRound(
    _ value: CGFloat,
    lowerBound: CGFloat,
    upperBound: CGFloat
  ) -> CGFloat {
    let high = max(lowerBound, upperBound)
    return min(max(routeGridRound(value), lowerBound), high)
  }

  public static func routeGridAligned(
    _ value: CGFloat,
    quantum: CGFloat = gridSize
  ) -> Bool {
    let step = max(quantum, 1)
    let remainder = abs(value).truncatingRemainder(dividingBy: step)
    return remainder < 0.001 || abs(step - remainder) < 0.001
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
