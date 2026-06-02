import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas route terminals")
@MainActor
struct PolicyCanvasRoutingTerminalTests {
  @Test("same endpoint routes use separate terminal anchors")
  func sameEndpointRoutesUseSeparateTerminalAnchors() {
    let scenario = defaultDisplayedRoutes()

    assertSeparateTerminalAnchors(
      scenario: scenario,
      endpoint: \.source,
      routePoint: { $0.points.first },
      label: "source"
    )
    assertSeparateTerminalAnchors(
      scenario: scenario,
      endpoint: \.target,
      routePoint: { $0.points.last },
      label: "target"
    )
  }

  @Test("same endpoint route anchors keep port spacing")
  func sameEndpointRouteAnchorsKeepPortSpacing() {
    let scenario = defaultDisplayedRoutes()

    assertTerminalAnchorSpacing(
      scenario: scenario,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "source"
      )
    )
    assertTerminalAnchorSpacing(
      scenario: scenario,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "target"
      )
    )
  }

  @Test("port marker layout matches route terminal offsets")
  func portMarkerLayoutMatchesRouteTerminalOffsets() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )

    assertMarkerOffsets(
      scenario: scenario,
      markerLayout: markerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "source"
      )
    )
    assertMarkerOffsets(
      scenario: scenario,
      markerLayout: markerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "target"
      )
    )
  }

  @Test("merge-deny failure family folds to a single shared source port marker")
  func mergeDenyFailureFamilyFoldsToOneSourcePortMarker() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )
    // The four reason-code fail edges fold into one merged wire, so the shared
    // evidence:merge:fail port collapses from four nested source dots to a
    // single attachment - the colliding fan the merge removes.
    guard
      let merged = scenario.edges.first(where: { $0.target.nodeID == "supervisor:merge-deny" })
    else {
      Issue.record("Expected a merged fail wire into merge-deny")
      return
    }
    #expect(merged.isMerged)
    let failEndpoint = PolicyCanvasPortEndpoint(
      nodeID: "evidence:merge",
      portID: "fail",
      kind: .output
    )
    guard let sourceSide = scenario.routes[merged.id].flatMap(policyCanvasRouteSourceSide) else {
      Issue.record("Expected a departure side for the merged fail wire")
      return
    }
    // One merged wire attaches at one source marker on its departure side (down
    // from the four nested dots the fan drew). Other sides are not queried: the
    // marker layout returns a default placeholder offset for any empty side, so
    // summing across sides would count placeholders, not real markers.
    let markers = markerLayout.markers(for: failEndpoint, side: sourceSide, isVisible: true)
    #expect(
      markers.count == 1,
      "the merged fail wire should attach at one source marker, saw \(markers.count)"
    )
  }

  @Test("merge evidence routes checks-pass horizontally across the merge group")
  func mergeEvidenceRoutesChecksPassHorizontally() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )
    guard let node = scenario.viewModel.node("evidence:merge") else {
      Issue.record("Expected Merge evidence node in default policy fixture")
      return
    }
    guard
      let edge = scenario.edges.first(where: { $0.id == "edge:evidence-pass" }),
      let route = scenario.routes[edge.id],
      let sourceIndex = node.outputPorts.firstIndex(where: { $0.id == edge.source.portID }),
      let targetNode = scenario.viewModel.node("risk:merge")
    else {
      Issue.record("Expected checks-pass route inside the merge group")
      return
    }
    let sourceEndpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: edge.source.portID,
      kind: .output
    )
    let targetEndpoint = PolicyCanvasPortEndpoint(
      nodeID: targetNode.id,
      portID: edge.target.portID,
      kind: .input
    )
    #expect(policyCanvasRouteSourceSide(route) == .trailing)
    #expect(policyCanvasRouteTargetSide(route) == .leading)

    let sourceMarkers = markerLayout.markers(for: sourceEndpoint, side: .trailing, isVisible: true)
    let targetMarkers = markerLayout.markers(for: targetEndpoint, side: .leading, isVisible: true)
    #expect(sourceMarkers.count == 1)
    #expect(targetMarkers.count == 1)
    let renderedSourceY =
      PolicyCanvasLayout.portY(index: sourceIndex, count: node.outputPorts.count)
      + sourceMarkers[0].axisOffset
    #expect(renderedSourceY >= 0)
    #expect(renderedSourceY <= PolicyCanvasLayout.nodeSize.height)
  }

  private func defaultDisplayedRoutes() -> PolicyCanvasTerminalScenario {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    return PolicyCanvasTerminalScenario(
      viewModel: viewModel,
      edges: edges,
      routes: policyCanvasDisplayedRoutes(
        viewModel: viewModel,
        edges: edges,
        portAnchors: viewModel.portAnchors(for: edges),
        router: PolicyCanvasVisibilityRouter()
      )
    )
  }

}

struct PolicyCanvasTerminalScenario {
  let viewModel: PolicyCanvasViewModel
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
}

struct PolicyCanvasTerminalAssertion {
  let role: PolicyCanvasRouteEndpointRole
  let endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>
  let routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?
  let routeSide: (PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide?
  let label: String
}

struct PolicyCanvasTerminalEntry {
  let id: String
  let point: CGPoint
  let spacing: CGFloat
  let side: PolicyCanvasPortSide?
}

struct PolicyCanvasRouteEndpointTestKey: Hashable {
  let nodeID: String
  let portID: String
  let kind: PolicyCanvasPortKind

  init(_ endpoint: PolicyCanvasPortEndpoint) {
    nodeID = endpoint.nodeID
    portID = endpoint.portID
    kind = endpoint.kind
  }
}

struct PolicyCanvasPointKey: Hashable {
  let x: Int
  let y: Int

  init(_ point: CGPoint) {
    x = Int((point.x * 1_000).rounded())
    y = Int((point.y * 1_000).rounded())
  }
}
