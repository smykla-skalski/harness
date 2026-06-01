import CoreGraphics
import Testing

@testable import HarnessMonitorUIPreviewable

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
    #expect(typeName(layout.layerOrdering) == "PolicyCanvasBarycenterCrossingReduction")
    #expect(
      typeName(layout.coordinateAssignment) == "PolicyCanvasLayeredGridCoordinateAssignment"
    )
    #expect(typeName(layout.groupPlacement) == "PolicyCanvasTightBoundingBoxGroupFrames")
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
}
