import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasAlgorithmSelectionXCTest: XCTestCase {
  func testPickerCatalogCoversEveryStage() {
    XCTAssertEqual(
      PolicyCanvasAlgorithmPickerCatalog.stageDescriptors.map(\.stage),
      PolicyCanvasAlgorithmStage.allCases
    )
    for descriptor in PolicyCanvasAlgorithmPickerCatalog.stageDescriptors {
      XCTAssertGreaterThanOrEqual(descriptor.options.count, 1)
      XCTAssertEqual(Set(descriptor.options.map(\.id)).count, descriptor.options.count)
    }
  }

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
