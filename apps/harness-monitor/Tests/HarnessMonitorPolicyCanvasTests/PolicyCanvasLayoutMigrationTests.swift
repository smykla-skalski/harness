import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas layout migration")
@MainActor
struct PolicyCanvasLayoutMigrationTests {
  @Test("mixed manual and automatic layout provenance round-trips through export")
  func mixedProvenanceRoundTripsThroughExport() {
    let initialViewModel = PolicyCanvasViewModel.sample()
    initialViewModel.load(
      document: overlappingDefaultPolicyDocument(revision: 910),
      simulation: nil,
      audit: nil
    )

    guard let manualIndex = initialViewModel.nodes.firstIndex(where: { $0.id == "action:router" })
    else {
      Issue.record("Expected action:router node in overlapping default policy fixture")
      return
    }
    let baselinePosition = initialViewModel.nodes[manualIndex].position
    let manualPosition = CGPoint(x: baselinePosition.x + 40, y: baselinePosition.y + 20)
    initialViewModel.nodes[manualIndex].position = manualPosition
    initialViewModel.nodes[manualIndex].layoutSource = .manual
    guard let autoIndex = initialViewModel.nodes.indices.first(where: { $0 != manualIndex })
    else {
      Issue.record("Expected at least one sibling node in overlapping default policy fixture")
      return
    }
    initialViewModel.nodes[autoIndex].layoutSource = .auto

    let exported = initialViewModel.exportDocument()
    let exportedSources = Dictionary(
      uniqueKeysWithValues: exported.layout.nodes.map { ($0.nodeId, $0.source) }
    )
    #expect(exportedSources["action:router"] == .manual)
    #expect(
      exported.layout.nodes.contains { layout in
        layout.nodeId != "action:router" && layout.source == .auto
      }
    )

    let reloadedViewModel = PolicyCanvasViewModel.sample()
    reloadedViewModel.load(document: exported, simulation: nil, audit: nil)

    #expect(reloadedViewModel.node("action:router")?.layoutSource == .manual)
    #expect(reloadedViewModel.node("action:router")?.position == manualPosition)
    #expect(
      reloadedViewModel.nodes.contains { node in
        node.id != "action:router" && node.layoutSource == .auto
      }
    )
  }

  @Test("reformatted routing hints round-trip through export and reload")
  func reformattedRoutingHintsRoundTripThroughExportAndReload() throws {
    let initialViewModel = PolicyCanvasViewModel.sample()
    initialViewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(revision: 911),
      simulation: nil,
      audit: nil
    )

    for index in initialViewModel.nodes.indices {
      initialViewModel.nodes[index].layoutSource = .manual
      initialViewModel.nodes[index].position = CGPoint(x: 60, y: 60)
    }
    initialViewModel.reflowLayout(
      preserveManualAnchors: false,
      force: true,
      requestsRouteComputation: false
    )

    let expectedRoutingHints = try #require(initialViewModel.routingHints)
    #expect(!expectedRoutingHints.isEmpty)

    let exported = initialViewModel.exportDocument()
    let reloadedViewModel = PolicyCanvasViewModel.sample()
    reloadedViewModel.load(document: exported, simulation: nil, audit: nil)

    #expect(reloadedViewModel.routingHints == expectedRoutingHints)
  }

  @Test("displayed route computation forwards persisted corridor hints")
  func displayedRouteComputationForwardsPersistedCorridorHints() throws {
    let hintedY: CGFloat = 432
    let source = PolicyCanvasNode(
      id: "source",
      title: "Source",
      kind: .actionStep,
      position: CGPoint(x: 40, y: 40)
    )
    let target = PolicyCanvasNode(
      id: "target",
      title: "Target",
      kind: .finish,
      position: CGPoint(x: 520, y: 260)
    )
    let edge = PolicyCanvasEdge(
      id: "edge:hinted",
      source: PolicyCanvasPortEndpoint(
        nodeID: "source",
        portID: "output-out",
        kind: .output,
        side: .trailing
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: "target",
        portID: "input-in",
        kind: .input,
        side: .leading
      ),
      label: "hinted"
    )
    let prepared = PolicyCanvasPreparedRouteInput(
      input: PolicyCanvasRouteWorkerInput(
        nodes: [source, target],
        groups: [],
        edges: [edge],
        fontScale: 1,
        routingHints: PolicyCanvasLayoutRoutingHints(
          edgeHints: [
            edge.id: PolicyCanvasEdgeCorridorHint(
              key: PolicyCanvasRouteCorridorKey(
                sourceScopeID: source.id,
                targetScopeID: target.id,
                targetNodeID: target.id,
                label: edge.label,
                laneIndex: 7
              ),
              horizontalLaneY: hintedY,
              verticalLaneX: nil
            )
          ]
        )
      )
    )

    let computation = prepared.routeComputation(
      router: PolicyCanvasCorridorHintEchoRouter(),
      algorithmSelection: .referenceRouting
    )
    let route = try #require(computation.routes[edge.id])

    #expect(route.points.contains { $0.y == hintedY })
  }

  @Test("pipeline layout JSON round-trips viewport and node positions")
  func pipelineLayoutJSONRoundTripsViewportAndNodePositions() throws {
    let layout = TaskBoardPolicyPipelineLayout(
      zoom: 1.25,
      offset: TaskBoardPolicyCanvasPoint(x: 320.4, y: 180.6),
      nodes: [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-a", x: 40, y: 60, source: .manual)
      ],
      routingHints: [
        TaskBoardPolicyPipelineEdgeRoutingHint(
          edgeId: "edge-a",
          sourceScopeId: "source-scope",
          targetScopeId: "target-scope",
          targetNodeId: "node-a",
          label: "approved",
          laneIndex: 2,
          horizontalLaneY: 180.5,
          verticalLaneX: 320.25,
          bundleOrdinal: 1,
          bundleSize: 3
        )
      ]
    )

    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(TaskBoardPolicyPipelineLayout.self, from: data)

    #expect(decoded.zoom == 1.25)
    #expect(decoded.offset == TaskBoardPolicyCanvasPoint(x: 320, y: 181))
    #expect(decoded.nodes == layout.nodes)
    #expect(decoded.routingHints == layout.routingHints)
  }

  @Test("pipeline layout decodes legacy node-only payload")
  func pipelineLayoutDecodesLegacyNodeOnlyPayload() throws {
    let data = Data("""
      {"nodes":[{"nodeId":"node-a","x":40,"y":60,"source":"manual"}]}
      """.utf8)

    let decoded = try JSONDecoder().decode(TaskBoardPolicyPipelineLayout.self, from: data)

    #expect(decoded.zoom == 1)
    #expect(decoded.offset == .zero)
    #expect(
      decoded.nodes == [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "node-a", x: 40, y: 60, source: .manual)
      ]
    )
    #expect(decoded.routingHints.isEmpty)
  }
}

private struct PolicyCanvasCorridorHintEchoRouter: PolicyCanvasEdgeRouter {
  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let hintedY = context.corridorHint?.horizontalLaneY ?? -1
    return PolicyCanvasEdgeRoute(
      points: [
        source,
        CGPoint(x: source.x, y: hintedY),
        target,
      ],
      labelPosition: CGPoint(x: (source.x + target.x) / 2, y: hintedY)
    )
  }
}
