import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas port order crossing")
struct PolicyCanvasPortOrderCrossingTests {
  @Test("trailing output ports order top-to-bottom by target Y to avoid crossing")
  func trailingPortsOrderByTargetY() throws {
    let source = policyCanvasPortOrderTestNode(
      id: "source",
      position: CGPoint(x: 200, y: 200),
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "a", title: "a", kind: .output),
        PolicyCanvasPort(id: "b", title: "b", kind: .output),
      ]
    )
    let highTarget = policyCanvasPortOrderTestNode(
      id: "high",
      position: CGPoint(x: 600, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let lowTarget = policyCanvasPortOrderTestNode(
      id: "low",
      position: CGPoint(x: 600, y: 500),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    // Port "a" (index 0, naturally the TOP slot) routes to the LOW target and
    // port "b" (index 1, naturally the BOTTOM slot) routes to the HIGH target.
    // With natural index order the two edges twist and cross right at the node;
    // the trailing markers must reorder so "b" takes the top slot.
    let edges = [
      PolicyCanvasEdge(
        id: "edge-a-low",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "a", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: lowTarget.id, portID: "in", kind: .input),
        label: "a",
        pinnedPortSide: false
      ),
      PolicyCanvasEdge(
        id: "edge-b-high",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "b", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: highTarget.id, portID: "in", kind: .input),
        label: "b",
        pinnedPortSide: false
      ),
    ]
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, highTarget, lowTarget],
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let aAnchor = CGPoint(
      x: source.position.x + PolicyCanvasLayout.nodeSize.width,
      y: source.position.y + PolicyCanvasLayout.portY(index: 0, count: 2)
    )
    let bAnchor = CGPoint(
      x: source.position.x + PolicyCanvasLayout.nodeSize.width,
      y: source.position.y + PolicyCanvasLayout.portY(index: 1, count: 2)
    )
    let routes = [
      "edge-a-low": PolicyCanvasEdgeRoute(
        points: [aAnchor, CGPoint(x: aAnchor.x + 150, y: aAnchor.y)],
        labelPosition: CGPoint(x: aAnchor.x + 75, y: aAnchor.y)
      ),
      "edge-b-high": PolicyCanvasEdgeRoute(
        points: [bAnchor, CGPoint(x: bAnchor.x + 150, y: bAnchor.y)],
        labelPosition: CGPoint(x: bAnchor.x + 75, y: bAnchor.y)
      ),
    ]

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let terminalA = try #require(layout.terminal(edgeID: "edge-a-low", role: .source))
    let terminalB = try #require(layout.terminal(edgeID: "edge-b-high", role: .source))

    #expect(terminalA.side == .trailing)
    #expect(terminalB.side == .trailing)
    let renderedA = PolicyCanvasLayout.portY(index: 0, count: 2) + terminalA.axisOffset
    let renderedB = PolicyCanvasLayout.portY(index: 1, count: 2) + terminalB.axisOffset
    // "b" routes to the higher target, so its marker must sit above "a".
    #expect(renderedB < renderedA)
  }

  @Test("bottom output ports order left-to-right by target X to avoid crossing")
  func bottomPortsOrderByTargetX() throws {
    let source = policyCanvasPortOrderTestNode(
      id: "source",
      position: CGPoint(x: 200, y: 200),
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "a", title: "a", kind: .output),
        PolicyCanvasPort(id: "b", title: "b", kind: .output),
      ]
    )
    let leftTarget = policyCanvasPortOrderTestNode(
      id: "left",
      position: CGPoint(x: 0, y: 600),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let rightTarget = policyCanvasPortOrderTestNode(
      id: "right",
      position: CGPoint(x: 500, y: 600),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    // Port "a" (index 0, naturally LEFT) routes to the RIGHT target and "b"
    // (index 1, naturally RIGHT) routes to the LEFT target: a twist that
    // crosses at the node unless the bottom markers reorder by target X.
    let edges = [
      PolicyCanvasEdge(
        id: "edge-a-right",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "a", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: rightTarget.id, portID: "in", kind: .input),
        label: "a",
        pinnedPortSide: false
      ),
      PolicyCanvasEdge(
        id: "edge-b-left",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "b", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: leftTarget.id, portID: "in", kind: .input),
        label: "b",
        pinnedPortSide: false
      ),
    ]
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, leftTarget, rightTarget],
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let aAnchor = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 0, count: 2),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    let bAnchor = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 1, count: 2),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    let routes = [
      "edge-a-right": PolicyCanvasEdgeRoute(
        points: [aAnchor, CGPoint(x: aAnchor.x, y: aAnchor.y + 150)],
        labelPosition: CGPoint(x: aAnchor.x, y: aAnchor.y + 75)
      ),
      "edge-b-left": PolicyCanvasEdgeRoute(
        points: [bAnchor, CGPoint(x: bAnchor.x, y: bAnchor.y + 150)],
        labelPosition: CGPoint(x: bAnchor.x, y: bAnchor.y + 75)
      ),
    ]

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let terminalA = try #require(layout.terminal(edgeID: "edge-a-right", role: .source))
    let terminalB = try #require(layout.terminal(edgeID: "edge-b-left", role: .source))

    #expect(terminalA.side == .bottom)
    #expect(terminalB.side == .bottom)
    let renderedA = PolicyCanvasLayout.portX(index: 0, count: 2) + terminalA.axisOffset
    let renderedB = PolicyCanvasLayout.portX(index: 1, count: 2) + terminalB.axisOffset
    // "b" routes to the left target, so its marker must sit left of "a".
    #expect(renderedB < renderedA)
  }

  @MainActor
  @Test("default graph merge-deny failure family routes do not cross on load or reflow")
  func failFamilyRoutesDoNotCrossEachOther() async throws {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    try await policyCanvasExpectNoFailFamilyCrossing(viewModel: viewModel, stage: "load")
    viewModel.reflowLayout()
    try await policyCanvasExpectNoFailFamilyCrossing(viewModel: viewModel, stage: "reflow")
  }
}

/// Computes the displayed routes for the current view-model state (with the
/// layout routing hints, exactly as the live canvas does) and asserts that no
/// two edges of the merge-deny failure family cross. Runs against both the
/// loaded layout and the reflowed layout so a fan that only tangles after
/// "Reformat" is still caught.
@MainActor
private func policyCanvasExpectNoFailFamilyCrossing(
  viewModel: PolicyCanvasViewModel,
  stage: String
) async throws {
  let input = PolicyCanvasRouteWorkerInput(
    nodes: viewModel.nodes,
    groups: viewModel.groups,
    edges: viewModel.edges,
    fontScale: 1,
    routingHints: viewModel.routingHints
  )
  let output = await PolicyCanvasRouteWorker().compute(input: input)
  let familyIDs = [
    "edge:evidence-fail:branch-protection-blocked",
    "edge:evidence-fail:checks-not-green",
    "edge:evidence-fail:reviewer-not-approved",
    "edge:evidence-fail:unresolved-requested-changes",
  ]
  let familyRoutes = familyIDs.compactMap { output.routes[$0] }
  #expect(familyRoutes.count == familyIDs.count)
  for left in familyRoutes.indices {
    for right in familyRoutes.indices where right > left {
      let crossing = policyCanvasFirstOrthogonalCrossing(
        familyRoutes[left], familyRoutes[right])
      let coordinate = "(\(Int(crossing?.x ?? 0)),\(Int(crossing?.y ?? 0)))"
      #expect(
        crossing == nil,
        "\(stage): \(familyIDs[left]) and \(familyIDs[right]) cross near \(coordinate)")
    }
  }
}

/// First interior point where an orthogonal segment of `left` crosses an
/// orthogonal segment of `right`, or nil when the two polylines never cross.
/// Touching at shared endpoints or running collinear does not count - only a
/// true horizontal-meets-vertical interior intersection.
func policyCanvasFirstOrthogonalCrossing(
  _ left: PolicyCanvasEdgeRoute,
  _ right: PolicyCanvasEdgeRoute
) -> CGPoint? {
  for leftSegment in zip(left.points, left.points.dropFirst()) {
    for rightSegment in zip(right.points, right.points.dropFirst()) {
      if let point = policyCanvasOrthogonalSegmentCrossing(leftSegment, rightSegment) {
        return point
      }
    }
  }
  return nil
}

private func policyCanvasOrthogonalSegmentCrossing(
  _ first: (CGPoint, CGPoint),
  _ second: (CGPoint, CGPoint)
) -> CGPoint? {
  let firstHorizontal = abs(first.0.y - first.1.y) < 0.001
  let firstVertical = abs(first.0.x - first.1.x) < 0.001
  let secondHorizontal = abs(second.0.y - second.1.y) < 0.001
  let secondVertical = abs(second.0.x - second.1.x) < 0.001
  if firstHorizontal, secondVertical {
    let crossX = second.0.x
    let crossY = first.0.y
    let withinFirst =
      crossX > min(first.0.x, first.1.x) + 0.001 && crossX < max(first.0.x, first.1.x) - 0.001
    let withinSecond =
      crossY > min(second.0.y, second.1.y) + 0.001 && crossY < max(second.0.y, second.1.y) - 0.001
    return withinFirst && withinSecond ? CGPoint(x: crossX, y: crossY) : nil
  }
  if firstVertical, secondHorizontal {
    return policyCanvasOrthogonalSegmentCrossing(second, first)
  }
  return nil
}

private func policyCanvasPortOrderTestNode(
  id: String,
  position: CGPoint,
  inputPorts: [PolicyCanvasPort],
  outputPorts: [PolicyCanvasPort]
) -> PolicyCanvasNode {
  var node = PolicyCanvasNode(id: id, title: id, kind: .condition, position: position)
  node.inputPorts = inputPorts
  node.outputPorts = outputPorts
  return node
}
