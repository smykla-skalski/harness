import Foundation
import XCTest

final class HarnessMonitorMobilePrivacyManifestTests: XCTestCase {
  func testMobileAndWatchTargetsBundlePrivacyManifest() throws {
    let projectURL = monitorAppRoot()
      .appendingPathComponent("Project.swift", isDirectory: false)
    let projectSource = try String(contentsOf: projectURL, encoding: .utf8)

    for targetName in [
      "watchWidgetsTarget",
      "watchAppTarget",
      "mobileAppTarget",
      "mobileWidgetsTarget",
    ] {
      let targetSource = try projectTargetSource(named: targetName, in: projectSource)
      XCTAssertTrue(
        targetSource.contains("\"Resources/PrivacyInfo.xcprivacy\""),
        "\(targetName) must bundle Resources/PrivacyInfo.xcprivacy"
      )
    }
  }

  private func monitorAppRoot(filePath: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(filePath)", isDirectory: false)
    for _ in 0..<3 {
      url.deleteLastPathComponent()
    }
    return url
  }

  private func projectTargetSource(named targetName: String, in projectSource: String) throws
    -> Substring
  {
    let marker = "private let \(targetName): Target"
    let start = try XCTUnwrap(projectSource.range(of: marker))
    let targetSource = projectSource[start.lowerBound...]
    if let nextTarget = targetSource.dropFirst().range(of: "\nprivate let ") {
      return projectSource[start.lowerBound..<nextTarget.lowerBound]
    }
    return targetSource
  }
}
