import XCTest

@testable import HarnessKit

final class HarnessLaunchModeTests: XCTestCase {
  func testDefaultsToLiveWhenEnvironmentValueIsMissing() {
    XCTAssertEqual(HarnessLaunchMode(environment: [:]), .live)
  }

  func testParsesPreviewAndEmptyModes() {
    XCTAssertEqual(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "preview"]),
      .preview
    )
    XCTAssertEqual(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "empty"]),
      .empty
    )
  }

  func testFallsBackToLiveForUnknownMode() {
    XCTAssertEqual(
      HarnessLaunchMode(environment: [HarnessLaunchMode.environmentKey: "mystery"]),
      .live
    )
  }
}
