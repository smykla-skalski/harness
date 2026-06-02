import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas routing")
@MainActor
struct PolicyCanvasRoutingTests {
  @Test("inter-group edge route avoids middle group")
  func interGroupEdgeRouteAvoidsMiddleGroup() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 572, y: 360),
      target: CGPoint(x: 1_944, y: 580),
      lane: 0,
      groups: defaultGroups,
      sourceGroupID: "entry",
      targetGroupID: "terminal"
    )

    #expect(!route.segmentsIntersect(rect: mergeGroup.frame))
    #expect(route.labelPosition.y == route.points[2].y)
  }

  @Test("blocked routes reserve separate label lanes")
  func blockedRoutesReserveSeparateLabelLanes() {
    let labels = (0..<3).map { lane in
      PolicyCanvasEdgeRoute(
        source: CGPoint(x: 572, y: 336 + CGFloat(lane * 24)),
        target: CGPoint(x: 1_944, y: 580 + CGFloat(lane * 140)),
        lane: lane,
        groups: defaultGroups,
        sourceGroupID: "entry",
        targetGroupID: "terminal"
      ).labelPosition
    }

    let sortedLabelY = labels.map(\.y).sorted()
    #expect(Set(sortedLabelY.map { Int($0.rounded()) }).count == labels.count)
    #expect(labelsHaveBadgeClearance(sortedLabelY))
  }

  @Test("adjacent group routes use gap corridor")
  func adjacentGroupRoutesUseGapCorridor() {
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 972, y: 360),
      target: CGPoint(x: 1_944, y: 1_012),
      lane: 8,
      groups: [mergeGroup, terminalGroup],
      sourceGroupID: "merge",
      targetGroupID: "terminal"
    )

    let verticalCorridorX = route.points[3].x
    #expect(verticalCorridorX > mergeGroup.frame.maxX)
    #expect(verticalCorridorX < terminalGroup.frame.minX)
  }

  @Test("adjacent group routes reserve badge clearance")
  func adjacentGroupRoutesReserveBadgeClearance() {
    let labelYs = (0..<3).map { lane in
      PolicyCanvasEdgeRoute(
        source: CGPoint(x: 972, y: 360),
        target: CGPoint(x: 1_944, y: 1_012),
        lane: lane,
        groups: [mergeGroup, terminalGroup],
        sourceGroupID: "merge",
        targetGroupID: "terminal"
      ).labelPosition.y
    }.sorted()

    #expect(labelsHaveBadgeClearance(labelYs))
  }

  @Test("same group return routes keep labels outside nodes")
  func sameGroupReturnRoutesKeepLabelsOutsideNodes() {
    let sourceNode = CGRect(x: 804, y: 312, width: 168, height: 96)
    let targetNode = CGRect(x: 804, y: 492, width: 168, height: 96)
    let route = PolicyCanvasEdgeRoute(
      source: CGPoint(x: sourceNode.maxX, y: sourceNode.midY),
      target: CGPoint(x: targetNode.minX, y: targetNode.midY),
      lane: 4,
      groups: [mergeGroup],
      sourceGroupID: "merge",
      targetGroupID: "merge"
    )

    #expect(!edgeLabelFrame(route.labelPosition).intersects(sourceNode))
    #expect(!edgeLabelFrame(route.labelPosition).intersects(targetNode))
    #expect(route.labelPosition.x > sourceNode.maxX)
  }

  @Test("same-group merge route uses trailing and leading ports")
  func sameGroupMergeRouteUsesTrailingAndLeadingPorts() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    guard let edge = viewModel.edges.first(where: { $0.id == "edge:evidence-pass" }),
      let source = viewModel.portAnchor(for: edge.source),
      let target = viewModel.portAnchor(for: edge.target)
    else {
      Issue.record("expected evidence-pass edge anchors")
      return
    }
    let route = PolicyCanvasEdgeRoute(
      source: source,
      target: target,
      lane: viewModel.edgeRouteLanes[edge.id, default: 0],
      groups: viewModel.groups,
      sourceGroupID: viewModel.node(edge.source.nodeID)?.groupID,
      targetGroupID: viewModel.node(edge.target.nodeID)?.groupID
    )

    #expect(edge.source.side == .trailing)
    #expect(edge.target.side == .leading)
    #expect(
      !edgeLabelFrame(route.labelPosition).intersects(nodeFrame("evidence:merge", in: viewModel)))
    #expect(!edgeLabelFrame(route.labelPosition).intersects(nodeFrame("risk:merge", in: viewModel)))
  }

  // Exercises the production label path: A* displayed routes resolved through
  // `policyCanvasResolvedLabelPositions` (the engine the live canvas renders),
  // not the legacy hand-coded `PolicyCanvasEdgeRoute(source:target:...)`
  // labelPosition that nothing in production constructs. Every rendered label
  // must clear every node body.
  @Test("default graph edge labels do not overlap nodes")
  func defaultGraphEdgeLabelsDoNotOverlapNodes() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)

    let edges = viewModel.edges
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: viewModel.portAnchors(for: edges),
      router: PolicyCanvasVisibilityRouter()
    )
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placement = edges.compactMap { edge -> PolicyCanvasLabelPlacementRoute? in
      guard !edge.label.isEmpty, let route = routes[edge.id] else {
        return nil
      }
      return PolicyCanvasLabelPlacementRoute(
        id: edge.id, label: edge.label, route: route, size: metrics.size(for: edge.label))
    }
    let nodeFrames = viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    }
    let labels = policyCanvasResolvedLabelPositions(
      routes: placement,
      nodeFrames: nodeFrames + policyCanvasGroupTitleFrames(viewModel.groups),
      routeFrames: policyCanvasRouteFrames(placement)
    )

    for entry in placement {
      guard let center = labels[entry.id] else {
        Issue.record("missing resolved label for \(entry.id)")
        continue
      }
      let labelFrame = edgeLabelFrame(center, size: entry.size)
      let overlapped = nodeFrames.first(where: { $0.intersects(labelFrame) })
      #expect(overlapped == nil, "\(entry.id) label overlaps a node body")
    }
  }

  @Test("default graph action routes avoid top-perimeter detours")
  func defaultGraphActionRoutesAvoidTopPerimeterDetours() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let edges = viewModel.edges
    let portAnchors = viewModel.portAnchors(for: edges)
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: portAnchors,
      router: PolicyCanvasVisibilityRouter()
    )

    guard
      let mergeFrame = viewModel.group("merge")?.frame,
      let terminalFrame = viewModel.group("terminal")?.frame,
      let defaultRoute = routes["edge:default"],
      let mutateRoute = routes["edge:mutate"],
      let unsafeRoute = routes["edge:unsafe"]
    else {
      Issue.record("Expected merge frame and action routes")
      return
    }

    guard
      let defaultBus = dominantHorizontalInternalLane(defaultRoute),
      let mutateBus = dominantHorizontalInternalLane(mutateRoute),
      let unsafeBus = dominantHorizontalInternalLane(unsafeRoute)
    else {
      Issue.record(
        """
        Expected horizontal internal lanes for action routes.
        default: \(defaultRoute.points)
        mutate: \(mutateRoute.points)
        unsafe: \(unsafeRoute.points)
        """
      )
      return
    }

    let topCorridorTolerance = PolicyCanvasLayout.gridSize
    #expect(defaultBus >= mergeFrame.minY - topCorridorTolerance)
    #expect(mutateBus >= mergeFrame.minY - topCorridorTolerance)
    #expect(unsafeBus >= mergeFrame.minY - topCorridorTolerance)
    #expect(defaultBus < terminalFrame.maxY)
    #expect(mutateBus < terminalFrame.maxY)
    #expect(unsafeBus < terminalFrame.maxY)
    #expect(Int(defaultBus.rounded()) != Int(mutateBus.rounded()))
  }

  @Test("default graph low-risk route avoids bottom-perimeter detour")
  func defaultGraphLowRiskRouteAvoidsBottomPerimeterDetour() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let edges = viewModel.edges
    let portAnchors = viewModel.portAnchors(for: edges)
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: portAnchors,
      router: PolicyCanvasVisibilityRouter()
    )

    guard
      let terminalFrame = viewModel.group("terminal")?.frame,
      let route = routes["edge:risk-low"]
    else {
      Issue.record("Expected terminal frame and risk-low route")
      return
    }

    guard let busY = dominantHorizontalInternalLane(route) else {
      Issue.record("Expected horizontal lane for risk-low route: \(route.points)")
      return
    }

    #expect(busY < terminalFrame.maxY)
  }

  private func labelsHaveBadgeClearance(_ sortedYs: [CGFloat]) -> Bool {
    zip(sortedYs, sortedYs.dropFirst()).allSatisfy { previous, next in
      next - previous >= PolicyCanvasLayout.edgeLabelHeight + 6
    }
  }

  func edgeLabelFrame(
    _ position: CGPoint,
    size: CGSize = CGSize(
      width: PolicyCanvasLayout.edgeLabelMaxWidth,
      height: PolicyCanvasLayout.edgeLabelHeight
    )
  ) -> CGRect {
    CGRect(
      x: position.x - size.width / 2,
      y: position.y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  func nodeFrame(_ nodeID: String, in viewModel: PolicyCanvasViewModel) -> CGRect {
    guard let node = viewModel.node(nodeID) else {
      return .null
    }
    return CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  }

  private func dominantInternalBusCoordinate(_ route: PolicyCanvasEdgeRoute) -> CGFloat? {
    guard route.points.count >= 4 else {
      return nil
    }
    var best: (length: CGFloat, coordinate: CGFloat)?
    for index in 1..<(route.points.count - 2) {
      let start = route.points[index]
      let end = route.points[index + 1]
      let length: CGFloat
      let coordinate: CGFloat
      if abs(start.y - end.y) < 0.001 {
        length = abs(end.x - start.x)
        coordinate = start.y
      } else if abs(start.x - end.x) < 0.001 {
        length = abs(end.y - start.y)
        coordinate = start.x
      } else {
        continue
      }
      if best.map({ length > $0.length }) ?? true {
        best = (length, coordinate)
      }
    }
    return best?.coordinate
  }

  private func dominantHorizontalInternalLane(_ route: PolicyCanvasEdgeRoute) -> CGFloat? {
    var best: (length: CGFloat, y: CGFloat)?
    for (start, end) in zip(route.points, route.points.dropFirst()) {
      guard abs(start.y - end.y) < 0.001 else {
        continue
      }
      let length = abs(end.x - start.x)
      if best.map({ length > $0.length }) ?? true {
        best = (length, start.y)
      }
    }
    return best?.y
  }
}
