import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

  @Test("default graph edge labels do not overlap nodes")
  func defaultGraphEdgeLabelsDoNotOverlapNodes() {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let nodeFrames = viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    }
    let lanes = viewModel.edgeRouteLanes
    for edge in viewModel.edges where !edge.label.isEmpty {
      guard let source = viewModel.portAnchor(for: edge.source),
        let target = viewModel.portAnchor(for: edge.target)
      else {
        Issue.record("missing anchors for \(edge.id)")
        return
      }
      let route = PolicyCanvasEdgeRoute(
        source: source,
        target: target,
        lane: lanes[edge.id, default: 0],
        groups: viewModel.groups,
        sourceGroupID: viewModel.node(edge.source.nodeID)?.groupID,
        targetGroupID: viewModel.node(edge.target.nodeID)?.groupID
      )
      let labelFrame = edgeLabelFrame(route.labelPosition)
      #expect(!nodeFrames.contains(where: { $0.intersects(labelFrame) }))
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

  @Test("display label placement separates labels along the route")
  func displayLabelPlacementSeparatesLabelsAlongRoute() {
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 360, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
        (
          id: "edge-b",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 20, y: 0), CGPoint(x: 380, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
      ],
      nodeFrames: [],
      labelSize: labelSize
    )

    guard let first = positions["edge-a"], let second = positions["edge-b"] else {
      Issue.record("expected both label positions")
      return
    }
    #expect(first.y == 0)
    #expect(second.y == 0)
    #expect(
      !edgeLabelFrame(first, size: labelSize).intersects(
        edgeLabelFrame(second, size: labelSize)))
  }

  @Test("display label placement keeps fallback on route when lanes are blocked")
  func displayLabelPlacementKeepsFallbackOnRouteWhenLanesAreBlocked() {
    let base = CGPoint(x: 110, y: 100)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 220, y: 0)],
            labelPosition: base
          )
        )
      ],
      nodeFrames: [
        CGRect(x: 0, y: -200, width: 220, height: 400)
      ],
      labelSize: CGSize(
        width: PolicyCanvasLayout.edgeLabelMaxWidth,
        height: PolicyCanvasLayout.edgeLabelHeight
      )
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.x == 110)
    #expect(position.y == 0)
  }

  @Test("display label placement avoids other route segments")
  func displayLabelPlacementAvoidsOtherRouteSegments() {
    let base = CGPoint(x: 180, y: 100)
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 100), CGPoint(x: 360, y: 100)],
            labelPosition: base
          )
        ),
        (
          id: "edge-b",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 180, y: -60), CGPoint(x: 180, y: 260)],
            labelPosition: CGPoint(x: 110, y: 180)
          )
        ),
      ],
      nodeFrames: [],
      routeFrames: [
        "edge-b": [CGRect(x: 170, y: -60, width: 20, height: 320)]
      ],
      labelSize: labelSize
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.x != base.x)
    #expect(position.y == base.y)
  }

  @Test("display label placement avoids route corners")
  func displayLabelPlacementAvoidsRouteCorners() {
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [
              CGPoint(x: 0, y: 0),
              CGPoint(x: 220, y: 0),
              CGPoint(x: 220, y: 120),
            ],
            labelPosition: CGPoint(x: 216, y: 0)
          )
        )
      ],
      nodeFrames: [],
      labelSize: labelSize
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.y == 0)
    #expect(position.x <= 140)
  }

  @Test("display label placement avoids unlabeled blocking routes")
  func displayLabelPlacementAvoidsUnlabeledBlockingRoutes() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.nodes = []
    viewModel.groups = []
    viewModel.edges = [
      PolicyCanvasEdge(
        id: "edge-a",
        source: PolicyCanvasPortEndpoint(nodeID: "source-a", portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: "target-a", portID: "in", kind: .input),
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      ),
      PolicyCanvasEdge(
        id: "edge-b",
        source: PolicyCanvasPortEndpoint(nodeID: "source-b", portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: "target-b", portID: "in", kind: .input),
        label: "",
        condition: "always",
        pinnedPortSide: true,
        kind: .flow,
        isAnimated: false
      ),
    ]
    let routes = [
      "edge-a": PolicyCanvasEdgeRoute(
        points: [CGPoint(x: 0, y: 100), CGPoint(x: 360, y: 100)],
        labelPosition: CGPoint(x: 180, y: 100)
      ),
      "edge-b": PolicyCanvasEdgeRoute(
        points: [CGPoint(x: 180, y: -40), CGPoint(x: 180, y: 240)],
        labelPosition: CGPoint(x: 180, y: 120)
      ),
    ]

    guard
      let position = policyCanvasResolvedLabelPositions(
        viewModel: viewModel,
        edges: viewModel.edges,
        routes: routes,
        fontScale: 1
      )["edge-a"]
    else {
      Issue.record("expected labelled edge position")
      return
    }

    let labelFrame = PolicyCanvasEdgeLabelMetrics(fontScale: 1).frame(
      for: "evidence failure",
      center: position
    )
    let blockingRouteFrame = CGRect(x: 170, y: -40, width: 20, height: 280)
    #expect(!labelFrame.intersects(blockingRouteFrame))
  }

  @Test("display label placement demotes shared trunks for bundled siblings")
  func displayLabelPlacementDemotesSharedTrunksForBundledSiblings() {
    let labelSize = CGSize(width: 88, height: PolicyCanvasLayout.edgeLabelHeight)
    let routes: [(id: String, route: PolicyCanvasEdgeRoute)] = [
      (
        id: "edge-a",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 40),
            CGPoint(x: 96, y: 40),
            CGPoint(x: 96, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 88),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
      (
        id: "edge-b",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 88),
            CGPoint(x: 128, y: 88),
            CGPoint(x: 128, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 136),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
      (
        id: "edge-c",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 136),
            CGPoint(x: 160, y: 136),
            CGPoint(x: 160, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 184),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes),
      labelSize: labelSize
    )

    let trunkLabels = positions.values.filter { abs($0.y) < 0.5 }
    #expect(trunkLabels.count <= 1)
    #expect(trunkLabels.count < positions.count)
  }

  @Test("display duplicate labels prefer vertical feeders over horizontal trunks")
  func displayDuplicateLabelsPreferVerticalFeedersOverHorizontalTrunks() {
    let labelSize = CGSize(width: 72, height: PolicyCanvasLayout.edgeLabelHeight)
    let routes = [
      PolicyCanvasLabelPlacementRoute(
        id: "edge-a",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 40),
            CGPoint(x: 80, y: 40),
            CGPoint(x: 80, y: 220),
            CGPoint(x: 360, y: 220),
          ],
          labelPosition: CGPoint(x: 220, y: 220)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-b",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 88),
            CGPoint(x: 120, y: 88),
            CGPoint(x: 120, y: 260),
            CGPoint(x: 360, y: 260),
          ],
          labelPosition: CGPoint(x: 240, y: 260)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-c",
        label: "action in",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 136),
            CGPoint(x: 160, y: 136),
            CGPoint(x: 160, y: 300),
            CGPoint(x: 360, y: 300),
          ],
          labelPosition: CGPoint(x: 260, y: 300)
        ),
        size: labelSize
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes)
    )

    guard
      let second = positions["edge-b"],
      let third = positions["edge-c"]
    else {
      Issue.record("expected duplicate label positions")
      return
    }

    #expect(abs(second.y - 260) > 0.5)
    #expect(abs(third.y - 300) > 0.5)
    #expect(abs(second.x - 120) < abs(second.x - 240))
    #expect(abs(third.x - 160) < abs(third.x - 260))
  }

  @Test("display duplicate labels avoid shared vertical trunks")
  func displayDuplicateLabelsAvoidSharedVerticalTrunks() {
    let label = "evidence failure"
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let labelSize = metrics.size(for: label)
    let routes = [
      PolicyCanvasLabelPlacementRoute(
        id: "edge-a",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 32),
            CGPoint(x: 120, y: 32),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 220, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 150)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-b",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 32, y: 80),
            CGPoint(x: 120, y: 80),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 260, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 160)
        ),
        size: labelSize
      ),
      PolicyCanvasLabelPlacementRoute(
        id: "edge-c",
        label: label,
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 64, y: 128),
            CGPoint(x: 120, y: 128),
            CGPoint(x: 120, y: 220),
            CGPoint(x: 300, y: 220),
          ],
          labelPosition: CGPoint(x: 120, y: 170)
        ),
        size: labelSize
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes)
    )

    let sharedVerticalTrunk = CGRect(x: 110, y: 80, width: 20, height: 140)
    let labelsOnTrunk = routes.compactMap { route in
      positions[route.id].map {
        edgeLabelFrame($0, size: route.size)
      }
    }.filter { $0.intersects(sharedVerticalTrunk) }

    #expect(labelsOnTrunk.count <= 1)
    #expect(labelsOnTrunk.count < routes.count)
  }

  private var defaultGroups: [PolicyCanvasGroup] {
    [entryGroup, mergeGroup, terminalGroup]
  }

  private var entryGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "entry",
      title: "Action routing",
      frame: CGRect(x: 360, y: 260, width: 256, height: 220),
      tone: .intake
    )
  }

  private var mergeGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "merge",
      title: "Merge checks",
      frame: CGRect(x: 760, y: 260, width: 256, height: 420),
      tone: .evaluation
    )
  }

  private var terminalGroup: PolicyCanvasGroup {
    PolicyCanvasGroup(
      id: "terminal",
      title: "Terminal decisions",
      frame: CGRect(x: 1_900, y: 480, width: 256, height: 1_220),
      tone: .release
    )
  }

  private func labelsHaveBadgeClearance(_ sortedYs: [CGFloat]) -> Bool {
    zip(sortedYs, sortedYs.dropFirst()).allSatisfy { previous, next in
      next - previous >= PolicyCanvasLayout.edgeLabelHeight + 6
    }
  }

  private func edgeLabelFrame(
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

  private func nodeFrame(_ nodeID: String, in viewModel: PolicyCanvasViewModel) -> CGRect {
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
