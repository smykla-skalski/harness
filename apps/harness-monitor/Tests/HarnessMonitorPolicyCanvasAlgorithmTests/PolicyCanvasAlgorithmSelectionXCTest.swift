import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasAlgorithmSelectionXCTest: XCTestCase {
  func testReferencePureSelectionResolvesPureLayoutAlgorithms() {
    let layout = PolicyCanvasLayoutAlgorithmRegistry.layoutAlgorithms(for: .referencePure)

    XCTAssertEqual(String(describing: type(of: layout.cycleBreaking)), "PolicyCanvasGreedyFeedbackArcReversal")
    XCTAssertEqual(String(describing: type(of: layout.rankAssignment)), "PolicyCanvasLongestPathLayering")
    XCTAssertEqual(String(describing: type(of: layout.longEdgeNormalization)), "PolicyCanvasUnitDummyChainNormalization")
    XCTAssertEqual(String(describing: type(of: layout.layerOrdering)), "PolicyCanvasBarycenterTransposeCrossingReduction")
    XCTAssertEqual(String(describing: type(of: layout.coordinateAssignment)), "PolicyCanvasBrandesKopfCoordinateAssignment")
    XCTAssertEqual(String(describing: type(of: layout.groupPlacement)), "PolicyCanvasLayeredClusterFramePacking")
    XCTAssertEqual(String(describing: type(of: layout.layoutPostProcessing)), "PolicyCanvasNoOpLayoutPostProcessing")
    XCTAssertEqual(String(describing: type(of: layout.metrics)), "PolicyCanvasSugiyamaCrossingMetrics")
  }
}
