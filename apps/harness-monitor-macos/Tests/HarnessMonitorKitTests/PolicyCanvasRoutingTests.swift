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

  @Test("same-column group route uses top and bottom ports")
  func sameColumnGroupRouteUsesTopAndBottomPorts() {
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

    #expect(edge.source.side == .bottom)
    #expect(edge.target.side == .top)
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

  @Test("default graph action routes use separate perimeter buses")
  func defaultGraphActionRoutesUseSeparatePerimeterBuses() {
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
      let defaultRoute = routes["edge:default"],
      let mutateRoute = routes["edge:mutate"],
      let unsafeRoute = routes["edge:unsafe"],
      let defaultBus = dominantInternalBusCoordinate(defaultRoute),
      let mutateBus = dominantInternalBusCoordinate(mutateRoute),
      let unsafeBus = dominantInternalBusCoordinate(unsafeRoute)
    else {
      Issue.record("Expected merge frame and action routes")
      return
    }

    #expect(defaultBus < mergeFrame.minY)
    #expect(mutateBus < mergeFrame.minY)
    #expect(unsafeBus > mergeFrame.maxY)
    #expect(Int(defaultBus.rounded()) != Int(mutateBus.rounded()))
  }

  @Test("display label placement separates overlapping capsules")
  func displayLabelPlacementSeparatesOverlappingCapsules() {
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 220, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
        (
          id: "edge-b",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 20, y: 0), CGPoint(x: 240, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
      ],
      nodeFrames: [],
      labelSize: CGSize(
        width: PolicyCanvasLayout.edgeLabelMaxWidth,
        height: PolicyCanvasLayout.edgeLabelHeight
      )
    )

    guard let first = positions["edge-a"], let second = positions["edge-b"] else {
      Issue.record("expected both label positions")
      return
    }
    #expect(!edgeLabelFrame(first).intersects(edgeLabelFrame(second)))
  }

  @Test("display label placement falls back horizontally when vertical lanes are blocked")
  func displayLabelPlacementFallsBackHorizontallyWhenVerticalLanesAreBlocked() {
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
    #expect(position.x != base.x)
    #expect(position.y == base.y)
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

  private func edgeLabelFrame(_ position: CGPoint) -> CGRect {
    CGRect(
      x: position.x - PolicyCanvasLayout.edgeLabelMaxWidth / 2,
      y: position.y - PolicyCanvasLayout.edgeLabelHeight / 2,
      width: PolicyCanvasLayout.edgeLabelMaxWidth,
      height: PolicyCanvasLayout.edgeLabelHeight
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
}
