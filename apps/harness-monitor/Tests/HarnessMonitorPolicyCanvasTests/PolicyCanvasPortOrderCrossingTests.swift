import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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

  @Test("vertical output route requests are coerced to horizontal sides")
  func verticalOutputRouteRequestsAreCoercedToHorizontalSides() throws {
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
    // The route geometry asks for bottom exits, but automatic canvas terminals
    // stay on horizontal sides.
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

    #expect(terminalA.side == .trailing)
    #expect(terminalB.side == .trailing)
    let renderedA = PolicyCanvasLayout.portY(index: 0, count: 2) + terminalA.axisOffset
    let renderedB = PolicyCanvasLayout.portY(index: 1, count: 2) + terminalB.axisOffset
    #expect(abs(renderedA + renderedB - PolicyCanvasLayout.nodeSize.height) < 0.001)
  }

  @MainActor
  @Test("exported policies persist optimized port order")
  func exportedPolicyPersistsOptimizedPortOrder() throws {
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
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.nodes = [source, highTarget, lowTarget]
    viewModel.groups = []
    viewModel.edges = [
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

    let document = viewModel.exportDocument()
    let exportedSource = try #require(document.nodes.first { $0.id.rawValue == source.id })

    #expect(exportedSource.outputs.map(\.id) == ["b", "a"])
  }

  @MainActor
  @Test("exported policies minimize cyclic port order preferences")
  func exportedPolicyMinimizesCyclicPortOrderPreferences() throws {
    let source = policyCanvasPortOrderTestNode(
      id: "source",
      position: CGPoint(x: 200, y: 200),
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "c", title: "c", kind: .output),
        PolicyCanvasPort(id: "b", title: "b", kind: .output),
        PolicyCanvasPort(id: "a", title: "a", kind: .output),
      ]
    )
    let highTarget = policyCanvasPortOrderTestNode(
      id: "high",
      position: CGPoint(x: 600, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let midTarget = policyCanvasPortOrderTestNode(
      id: "mid",
      position: CGPoint(x: 600, y: 250),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let lowTarget = policyCanvasPortOrderTestNode(
      id: "low",
      position: CGPoint(x: 600, y: 500),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
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
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.nodes = [source, highTarget, midTarget, lowTarget, leftTarget, rightTarget]
    viewModel.groups = []
    viewModel.edges = [
      policyCanvasPortOrderTestEdge("edge-a-high", from: source, port: "a", to: highTarget),
      policyCanvasPortOrderTestEdge("edge-b-mid", from: source, port: "b", to: midTarget),
      policyCanvasPortOrderTestEdge("edge-c-low", from: source, port: "c", to: lowTarget),
      policyCanvasPortOrderTestEdge(
        "edge-c-left",
        from: source,
        port: "c",
        side: .bottom,
        to: leftTarget
      ),
      policyCanvasPortOrderTestEdge(
        "edge-a-right",
        from: source,
        port: "a",
        side: .bottom,
        to: rightTarget
      ),
    ]

    let document = viewModel.exportDocument()
    let exportedSource = try #require(document.nodes.first { $0.id.rawValue == source.id })

    #expect(exportedSource.outputs.map(\.id) == ["b", "a", "c"])
  }

  // The merge-deny fail family folds into one merged wire, so there is no longer
  // a four-edge fan that could tangle on load or reflow - the merged wire's clean
  // single approach is covered by PolicyCanvasMergedFanInTests and the MergeDeny
  // and route-interiors-avoid-node-bodies tests.
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

private func policyCanvasPortOrderTestEdge(
  _ id: String,
  from source: PolicyCanvasNode,
  port: String,
  side: PolicyCanvasPortSide = .trailing,
  to target: PolicyCanvasNode
) -> PolicyCanvasEdge {
  PolicyCanvasEdge(
    id: id,
    source: PolicyCanvasPortEndpoint(
      nodeID: source.id,
      portID: port,
      kind: .output,
      side: side
    ),
    target: PolicyCanvasPortEndpoint(nodeID: target.id, portID: "in", kind: .input),
    label: port,
    pinnedPortSide: false
  )
}
