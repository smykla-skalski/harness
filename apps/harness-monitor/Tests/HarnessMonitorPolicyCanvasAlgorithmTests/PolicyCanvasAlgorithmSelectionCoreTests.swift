import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas algorithm selection core")
struct PolicyCanvasAlgorithmSelectionCoreTests {
  @Test("reference pure selection resolves to pure layout implementations")
  func referencePureSelectionResolvesToPureLayoutImplementations() {
    let layout = PolicyCanvasLayoutAlgorithmRegistry.layoutAlgorithms(for: .referencePure)

    #expect(typeName(layout.cycleBreaking) == "PolicyCanvasGreedyFeedbackArcReversal")
    #expect(typeName(layout.rankAssignment) == "PolicyCanvasLongestPathLayering")
    #expect(typeName(layout.longEdgeNormalization) == "PolicyCanvasUnitDummyChainNormalization")
    #expect(typeName(layout.layerOrdering) == "PolicyCanvasBarycenterTransposeCrossingReduction")
    #expect(typeName(layout.coordinateAssignment) == "PolicyCanvasBrandesKopfCoordinateAssignment")
    #expect(typeName(layout.groupPlacement) == "PolicyCanvasLayeredClusterFramePacking")
    #expect(typeName(layout.layoutPostProcessing) == "PolicyCanvasNoOpLayoutPostProcessing")
    #expect(typeName(layout.metrics) == "PolicyCanvasSugiyamaCrossingMetrics")
  }

  @Test("empty selection falls back to harness current defaults")
  func emptySelectionFallsBackToHarnessCurrentDefaults() {
    let selection = PolicyCanvasAlgorithmSelection()

    for stage in PolicyCanvasAlgorithmStage.allCases {
      #expect(selection.algorithmID(for: stage) == PolicyCanvasAlgorithmDefaults.harnessCurrentID(for: stage))
    }
  }

  private func typeName(_ value: some Any) -> String {
    String(describing: type(of: value))
  }
}
