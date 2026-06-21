import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// A node drag re-routes through the selective live path, which funnels every
/// edge through `repairedRouteComputation`. That path used to hard-code the naive
/// polyline-midpoint label placement, which drops each label on its route
/// midpoint with zero obstacle avoidance - so dragging a node under a frozen
/// edge's label left the label sitting on the node body. These tests pin that a
/// selective recompute places labels with the obstacle-aware algorithm the full
/// reconverge already uses, keeping labels off foreign node bodies.
@Suite("Policy canvas selective drag label placement")
struct PolicyCanvasSelectiveDragLabelPlacementTests {
  @Test("dragging a node under a frozen edge label keeps the label off the body")
  func draggingNodeUnderFrozenLabelKeepsLabelOffBody() async throws {
    let labelText = "blocked"
    let source = policyCanvasMarkerTestNode(
      id: "edge-source",
      position: CGPoint(x: 0, y: 100),
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "edge-target",
      position: CGPoint(x: 700, y: 100),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    var obstacle = policyCanvasMarkerTestNode(
      id: "obstacle",
      position: CGPoint(x: 300, y: 520),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let obstacleSink = policyCanvasMarkerTestNode(
      id: "obstacle-sink",
      position: CGPoint(x: 300, y: 760),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let labeledEdge = PolicyCanvasEdge(
      id: "labeled",
      source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: target.id, portID: "in", kind: .input),
      label: labelText
    )
    let obstacleEdge = PolicyCanvasEdge(
      id: "obstacle-edge",
      source: PolicyCanvasPortEndpoint(nodeID: obstacle.id, portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: obstacleSink.id, portID: "in", kind: .input),
      label: ""
    )

    let worker = PolicyCanvasRouteWorker()
    let previousInput = PolicyCanvasRouteWorkerInput(
      nodes: [source, target, obstacle, obstacleSink],
      groups: [],
      edges: [labeledEdge, obstacleEdge],
      fontScale: 1,
      algorithmSelection: .referenceRouting
    )
    let previous = await worker.compute(input: previousInput)
    let labeledRoute = try #require(previous.routes[labeledEdge.id])
    let labelMidpoint = labeledRoute.arcLengthMidpoint

    // Drag the obstacle up so its body sits just below the labeled edge's route
    // midpoint: the route line clears the body, but the naive midpoint label box
    // dips into it. The 6pt gap keeps the frozen route from intersecting the body
    // (so body-hit repair does not reroute it), isolating the label placement.
    obstacle.position = CGPoint(
      x: labelMidpoint.x - (PolicyCanvasLayout.nodeSize.width / 2),
      y: labelMidpoint.y + 6
    )
    let obstacleFrame = policyCanvasNodeFrame(obstacle)
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)

    // Precondition: the naive midpoint placement really does land the label on
    // the dragged body, so a passing test proves the obstacle-aware placement,
    // not a lucky geometry.
    #expect(metrics.frame(for: labelText, center: labelMidpoint).intersects(obstacleFrame))

    let draggedInput = PolicyCanvasRouteWorkerInput(
      nodes: [source, target, obstacle, obstacleSink],
      groups: [],
      edges: [labeledEdge, obstacleEdge],
      fontScale: 1,
      algorithmSelection: .referenceRouting
    )
    let dragged = await worker.computeSelective(
      input: draggedInput,
      movedNodeIDs: [obstacle.id],
      previous: previous
    )

    // The frozen labeled route is unchanged by the drag (the obstacle is not its
    // endpoint and the route does not cross the body), so the label must have
    // been re-seated off the body rather than left on its route midpoint.
    let draggedRoute = try #require(dragged.routes[labeledEdge.id])
    #expect(draggedRoute == labeledRoute)
    let labelCenter = dragged.labelPositions[labeledEdge.id] ?? draggedRoute.arcLengthMidpoint
    let labelFrame = metrics.frame(for: labelText, center: labelCenter)
    #expect(
      !labelFrame.intersects(obstacleFrame),
      """
      selective drag recompute placed the label on the dragged node body
      labelCenter=\(labelCenter)
      labelFrame=\(labelFrame)
      obstacleFrame=\(obstacleFrame)
      """
    )
  }
}
