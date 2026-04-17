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
    #expect(
      HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment).path
        == "/tmp/harness-xdg/harness/observability/config.json"
    )
  }

  @Test("Uses daemon data home before XDG data home")
  func usesDaemonDataHomeBeforeXDGDataHome() {
    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: "/tmp/harness-daemon-home",
        "XDG_DATA_HOME": "/tmp/harness-xdg",
      ],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == "/tmp/harness-daemon-home/harness/daemon"
    )
  }

  @Test(
    "External daemon mode defaults to the shared monitor data root when no explicit data home is set"
  )
  func externalDaemonModeDefaultsToSharedMonitorDataRoot() {
    let environment = HarnessMonitorEnvironment(
      values: [DaemonOwnership.environmentKey: "1"],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let expectedRoot: String
    if let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: HarnessMonitorAppGroup.identifier
    ) {
      expectedRoot =
        containerURL
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .path
    } else {
      expectedRoot = "/Users/example/Library/Application Support/harness/daemon"
    }

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == expectedRoot
    )
  }

  @Test("External daemon mode still prefers the app group when one is available")
  func externalDaemonModePrefersAppGroup() {
    let environment = HarnessMonitorEnvironment(
      values: [
        DaemonOwnership.environmentKey: "1",
        HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier,
      ],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/daemon"
    )
  }

  @Test("Uses app group environment fallback")
  func usesAppGroupEnvironmentFallback() {
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.authTokenURL(using: environment).path
        == "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/daemon/auth-token"
    )
  }

  @Test("Shared observability config defaults to Application Support")
  func sharedObservabilityConfigDefaultsToApplicationSupport() {
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    #expect(
      HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment).path
        == "/Users/example/Library/Application Support/harness/observability/config.json"
    )
  }

  @Test("Launch agent plist path is bundle relative")
  func launchAgentPlistPathIsBundleRelative() {
    #expect(HarnessMonitorPaths.launchAgentPlistName == "io.harnessmonitor.daemon.plist")
    #expect(
      HarnessMonitorPaths.launchAgentBundleRelativePath
        == "Contents/Library/LaunchAgents/io.harnessmonitor.daemon.plist"
    )
  }
}
