import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas algorithm selection")
struct PolicyCanvasAlgorithmSelectionTests {
  @Test("reference pure selection resolves to pure component implementations")
  func referencePureSelectionResolvesToPureComponentImplementations() {
    let layout = PolicyCanvasAlgorithmRegistry.layoutAlgorithms(for: .referencePure)
    let routing = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: .referencePure)

    #expect(typeName(layout.cycleBreaking) == "PolicyCanvasGreedyFeedbackArcReversal")
    #expect(typeName(layout.rankAssignment) == "PolicyCanvasLongestPathLayering")
    #expect(typeName(layout.longEdgeNormalization) == "PolicyCanvasUnitDummyChainNormalization")
    #expect(typeName(layout.layerOrdering) == "PolicyCanvasBarycenterTransposeCrossingReduction")
    #expect(
      typeName(layout.coordinateAssignment) == "PolicyCanvasBrandesKopfCoordinateAssignment"
    )
    #expect(typeName(layout.groupPlacement) == "PolicyCanvasLayeredClusterFramePacking")
    #expect(typeName(layout.layoutPostProcessing) == "PolicyCanvasNoOpLayoutPostProcessing")
    #expect(typeName(routing.edgeRouter) == "PolicyCanvasOrthogonalVisibilityGraphAStarRouter")
    #expect(typeName(routing.routeSelection) == "PolicyCanvasFirstFeasibleRouteSelection")
    #expect(typeName(routing.routePostProcessing) == "PolicyCanvasCollinearRouteCompression")
    #expect(typeName(routing.labelPlacement) == "PolicyCanvasPolylineMidpointLabelPlacement")
  }

  @Test("automatic layout uses one deterministic ELK path")
  func automaticLayoutUsesOneDeterministicElkPath() throws {
    let fixture = Self.linearFixture()
    let reference = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges
      )
    )
    let mixed = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges
      )
    )

    #expect(reference.nodePositions["source"]!.x < reference.nodePositions["gate"]!.x)
    #expect(reference.nodePositions["gate"]!.x < reference.nodePositions["sink"]!.x)
    #expect(reference.nodePositions == mixed.nodePositions)
    #expect(reference.precomputedRoutes?.routes.count == fixture.edges.count)
    #expect(mixed.precomputedRoutes?.routes.count == fixture.edges.count)
  }

  @Test("route worker accepts reference routing components")
  func routeWorkerAcceptsReferenceRoutingComponents() async {
    let fixture = Self.linearFixture()
    let output = await PolicyCanvasRouteWorker().compute(
      input: PolicyCanvasRouteWorkerInput(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges,
        fontScale: 1,
        algorithmSelection: .referencePure
      )
    )

    #expect(output.routes["edge-source-gate"] != nil)
    #expect(output.routes["edge-gate-sink"] != nil)
    #expect(output.labelPositions["edge-source-gate"] != nil)
  }

  @Test("workspace does not render synthetic routes while worker catches up")
  func workspaceDoesNotRenderSyntheticRoutesWhileWorkerCatchesUp() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")

    #expect(!source.contains("PolicyCanvasRouteWorkerOutput.fallback("))
    #expect(!source.contains("policyCanvasProvisionalRouteOutput("))
    #expect(!source.contains("policyCanvasNodeBoundsPlaceholderOutput("))
    #expect(source.contains("let routeOutput = projectedRouteResult.output"))
    #expect(source.contains("let routeOutputIsCurrentGraphMissing ="))
    #expect(source.contains("guard routeOutputNeedsRefresh else { return }"))
  }

  @Test("greedy feedback arc reversal returns an acyclic orientation")
  func greedyFeedbackArcReversalReturnsAcyclicOrientation() {
    let edges = [
      PolicyCanvasLayoutEdge(id: "a-b", sourceNodeID: "a", targetNodeID: "b"),
      PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      PolicyCanvasLayoutEdge(id: "c-a", sourceNodeID: "c", targetNodeID: "a"),
      PolicyCanvasLayoutEdge(id: "c-d", sourceNodeID: "c", targetNodeID: "d"),
    ]
    let output = PolicyCanvasGreedyFeedbackArcReversal().breakCycles(
      input: PolicyCanvasCycleBreakingInput(
        nodeIDs: ["a", "b", "c", "d"],
        originalOrder: ["a": 0, "b": 1, "c": 2, "d": 3],
        edges: edges
      )
    )

    #expect(output.map(\.id).sorted() == edges.map(\.id).sorted())
    #expect(Self.isAcyclic(nodeIDs: ["a", "b", "c", "d"], edges: output))
  }

  private static func linearFixture() -> (nodes: [PolicyCanvasNode], edges: [PolicyCanvasEdge]) {
    let source = PolicyCanvasNode(id: "source", title: "Source", kind: .source, position: .zero)
    let gate = PolicyCanvasNode(id: "gate", title: "Gate", kind: .condition, position: .zero)
    let sink = PolicyCanvasNode(id: "sink", title: "Sink", kind: .decision, position: .zero)
    return (
      [source, gate, sink],
      [
        PolicyCanvasEdge(
          id: "edge-source-gate",
          source: PolicyCanvasPortEndpoint(
            nodeID: source.id,
            portID: source.outputPorts[0].id,
            kind: .output
          ),
          target: PolicyCanvasPortEndpoint(
            nodeID: gate.id,
            portID: gate.inputPorts[0].id,
            kind: .input
          ),
          label: "review"
        ),
        PolicyCanvasEdge(
          id: "edge-gate-sink",
          source: PolicyCanvasPortEndpoint(
            nodeID: gate.id,
            portID: gate.outputPorts[0].id,
            kind: .output
          ),
          target: PolicyCanvasPortEndpoint(
            nodeID: sink.id,
            portID: sink.inputPorts[0].id,
            kind: .input
          ),
          label: "approved"
        ),
      ]
    )
  }

  private func typeName<T>(_ value: T) -> String {
    String(describing: type(of: value))
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func sourceFunction(
    named marker: String,
    endingBefore terminator: String,
    in source: String
  ) throws -> String {
    guard let start = source.range(of: marker) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let remaining = source[start.upperBound...]
    guard let end = remaining.range(of: terminator) else {
      return String(source[start.lowerBound...])
    }
    return String(source[start.lowerBound..<end.lowerBound])
  }

  private static func isAcyclic(
    nodeIDs: [String],
    edges: [PolicyCanvasLayoutEdge]
  ) -> Bool {
    let successors = edges.reduce(into: [String: [String]]()) { partial, edge in
      partial[edge.sourceNodeID, default: []].append(edge.targetNodeID)
    }
    var visiting: Set<String> = []
    var visited: Set<String> = []

    func visit(_ nodeID: String) -> Bool {
      if visiting.contains(nodeID) {
        return false
      }
      if visited.contains(nodeID) {
        return true
      }
      visiting.insert(nodeID)
      for successor in successors[nodeID] ?? [] where !visit(successor) {
        return false
      }
      visiting.remove(nodeID)
      visited.insert(nodeID)
      return true
    }

    return nodeIDs.allSatisfy(visit)
  }
}
