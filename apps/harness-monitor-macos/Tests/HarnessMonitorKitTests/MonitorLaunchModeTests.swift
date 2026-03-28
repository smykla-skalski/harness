import XCTest

@testable import HarnessMonitorKit

final class MonitorLaunchModeTests: XCTestCase {
  func testDefaultsToLiveWhenEnvironmentValueIsMissing() {
    XCTAssertEqual(MonitorLaunchMode(environment: [:]), .live)
  }

  func testParsesPreviewAndEmptyModes() {
    XCTAssertEqual(
      MonitorLaunchMode(environment: [MonitorLaunchMode.environmentKey: "preview"]),
      .preview
    )
    XCTAssertEqual(
      MonitorLaunchMode(environment: [MonitorLaunchMode.environmentKey: "empty"]),
      .empty
    )
  }

  func testFallsBackToLiveForUnknownMode() {
    XCTAssertEqual(
      MonitorLaunchMode(environment: [MonitorLaunchMode.environmentKey: "mystery"]),
      .live
    )
  }
}
