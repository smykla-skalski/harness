import Foundation
import XCTest

@testable import HarnessKit

final class HarnessPathsTests: XCTestCase {
  func testUsesXDGDataHomeWhenPresent() {
    let environment = HarnessEnvironment(
      values: ["XDG_DATA_HOME": "/tmp/harness-xdg"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      HarnessPaths.manifestURL(using: environment).path,
      "/tmp/harness-xdg/harness/daemon/manifest.json"
    )
  }

  func testFallsBackToApplicationSupportOnMacOS() {
    let environment = HarnessEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      HarnessPaths.authTokenURL(using: environment).path,
      "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )
  }

  func testLaunchAgentLivesInUserLibraryLaunchAgents() {
    let environment = HarnessEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      HarnessPaths.launchAgentURL(using: environment).path,
      "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
    )
  }
}
