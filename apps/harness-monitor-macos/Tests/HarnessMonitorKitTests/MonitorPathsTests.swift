import Foundation
import HarnessMonitorKit
import XCTest

final class MonitorPathsTests: XCTestCase {
  func testUsesXDGDataHomeWhenPresent() {
    let environment = MonitorEnvironment(
      values: ["XDG_DATA_HOME": "/tmp/harness-xdg"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.manifestURL(using: environment).path,
      "/tmp/harness-xdg/harness/daemon/manifest.json"
    )
  }

  func testFallsBackToApplicationSupportOnMacOS() {
    let environment = MonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.authTokenURL(using: environment).path,
      "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )
  }

  func testLaunchAgentLivesInUserLibraryLaunchAgents() {
    let environment = MonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    XCTAssertEqual(
      MonitorPaths.launchAgentURL(using: environment).path,
      "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
    )
  }
}
