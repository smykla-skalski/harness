import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor paths")
struct HarnessMonitorPathsTests {
  @Test("Uses XDG data home when present")
  func usesXDGDataHomeWhenPresent() {
    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": "/tmp/harness-xdg"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.manifestURL(using: environment).path
        == "/tmp/harness-xdg/harness/daemon/manifest.json"
    )
  }

  @Test("Falls back to Application Support on macOS")
  func fallsBackToApplicationSupportOnMacOS() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.authTokenURL(using: environment).path
        == "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )
  }

  @Test("Launch agent lives in the user LaunchAgents directory")
  func launchAgentLivesInUserLibraryLaunchAgents() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.launchAgentURL(using: environment).path
        == "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
    )
  }
}
