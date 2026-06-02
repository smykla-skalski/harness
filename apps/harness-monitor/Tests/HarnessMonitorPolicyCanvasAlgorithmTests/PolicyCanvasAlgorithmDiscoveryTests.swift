import XCTest

@testable import HarnessMonitorPolicyCanvasAlgorithms

final class PolicyCanvasAlgorithmDiscoveryTests: XCTestCase {
  func testPickerCatalogCoversEveryStage() {
    XCTAssertEqual(
      PolicyCanvasAlgorithmPickerCatalog.stageDescriptors.map(\.stage),
      PolicyCanvasAlgorithmStage.allCases
    )
  }
}
