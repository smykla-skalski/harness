import Foundation
import Testing

@testable import HarnessKit

@Suite("Harness paths")
struct HarnessPathsTests {
  @Test("Uses XDG data home when present")
  func usesXDGDataHomeWhenPresent() {
    let environment = HarnessEnvironment(
      values: ["XDG_DATA_HOME": "/tmp/harness-xdg"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessPaths.manifestURL(using: environment).path
        == "/tmp/harness-xdg/harness/daemon/manifest.json"
    )
  }

  @Test("Falls back to Application Support on macOS")
  func fallsBackToApplicationSupportOnMacOS() {
    let environment = HarnessEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessPaths.authTokenURL(using: environment).path
        == "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )
  }

  @Test("Launch agent lives in the user LaunchAgents directory")
  func launchAgentLivesInUserLibraryLaunchAgents() {
    let environment = HarnessEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessPaths.launchAgentURL(using: environment).path
        == "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
    )
  }
}
