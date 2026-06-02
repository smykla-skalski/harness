import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas algorithm selection")
struct PolicyCanvasAlgorithmSelectionTests {
  @Test("picker catalog exposes concrete algorithms for every stage")
  func pickerCatalogExposesConcreteAlgorithmsForEveryStage() {
    let descriptors = PolicyCanvasAlgorithmPickerCatalog.stageDescriptors

    #expect(descriptors.map(\.stage) == PolicyCanvasAlgorithmStage.allCases)
    for descriptor in descriptors {
      #expect(descriptor.options.count >= 2)
      #expect(Set(descriptor.options.map(\.id)).count == descriptor.options.count)
      #expect(
        !descriptor.options.contains { option in
          option.name.localizedCaseInsensitiveContains("variant")
        }
      )
    }
  }

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

  @Test("reference and mixed layout selections produce deterministic positions")
  func referenceAndMixedLayoutSelectionsProduceDeterministicPositions() throws {
    let fixture = Self.linearFixture()
    let reference = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges,
        algorithmSelection: .referencePure
      )
    )
    let mixedSelection = PolicyCanvasAlgorithmSelection.harnessCurrent.replacing(
      stage: .coordinateAssignment,
      with: PolicyCanvasAlgorithmDefaults.layeredGridCoordinateAssignment
    )
    let mixed = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges,
        algorithmSelection: mixedSelection
      )
    )

    #expect(reference.nodePositions["source"]!.x < reference.nodePositions["gate"]!.x)
    #expect(reference.nodePositions["gate"]!.x < reference.nodePositions["sink"]!.x)
    #expect(mixed.nodePositions["source"]!.x < mixed.nodePositions["gate"]!.x)
    #expect(mixed.nodePositions["gate"]!.x < mixed.nodePositions["sink"]!.x)
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

  @Test("fallback route output renders edges without invoking route worker")
  func fallbackRouteOutputRendersEdgesWithoutRouteWorker() {
    let fixture = Self.linearFixture()
    let output = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        nodes: fixture.nodes,
        groups: [],
        edges: fixture.edges,
        fontScale: 1
      )
    )

    #expect(output.routes.keys.sorted() == fixture.edges.map(\.id).sorted())
    #expect(output.signature.routeCount == fixture.edges.count)
  }

  @Test("fallback route output stays cheap for instant canvas switches")
  func fallbackRouteOutputStaysCheapForInstantCanvasSwitches() throws {
    let source = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasRouteWorkerTypes.swift"
    )
    let fallbackFunction = try sourceFunction(
      named: "static func fallback(for input: PolicyCanvasRouteWorkerInput) -> Self",
      endingBefore: "\n  init(",
      in: source
    )

    #expect(!fallbackFunction.contains("resolvedLabelPositions("))
    #expect(!fallbackFunction.contains("portVisibility("))
    #expect(!fallbackFunction.contains("portMarkerLayout("))
    #expect(!fallbackFunction.contains("accessibilityEdgeEntries("))
    #expect(!fallbackFunction.contains("nodeAccessibilityValuesByID("))
    #expect(!fallbackFunction.contains("accessibilityNodeEntries("))
    #expect(!fallbackFunction.contains("connectTargetsByNodeID("))
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
