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

  @Test("Generated caches use a noindex root")
  func generatedCachesUseNoIndexRoot() {
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let expectedCacheRoot =
      "/Users/example/Library/Group Containers/Q498EB36N4.io.harnessmonitor/harness/cache.noindex"

    #expect(
      HarnessMonitorPaths.thumbnailCacheRoot(using: environment).path
        == "\(expectedCacheRoot)/thumbnails"
    )
    #expect(
      HarnessMonitorPaths.notificationCacheRoot(using: environment).path
        == "\(expectedCacheRoot)/notifications"
    )
  }

  @Test("Preparing a generated cache directory removes indexed legacy cache directories")
  func preparingGeneratedCacheDirectoryRemovesLegacyCacheDirectories() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-generated-cache-\(UUID().uuidString)", isDirectory: true)
    let targetDirectory =
      root.appendingPathComponent("cache.noindex/notifications", isDirectory: true)
    let legacyDirectory =
      root.appendingPathComponent("cache/notifications", isDirectory: true)

    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(
      to: legacyDirectory.appendingPathComponent("legacy.txt"),
      options: .atomic
    )

    try HarnessMonitorPaths.prepareGeneratedCacheDirectory(
      targetDirectory,
      cleaningLegacyDirectories: [legacyDirectory]
    )

    #expect(FileManager.default.fileExists(atPath: targetDirectory.path))
    #expect(FileManager.default.fileExists(atPath: legacyDirectory.path) == false)
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

  @Test("MCP socket filename stays within realistic Unix socket path limits")
  func mcpSocketFilenameStaysWithinUnixSocketPathLimits() {
    let homeDirectory = URL(fileURLWithPath: "/Users/bart.smykla@konghq.com", isDirectory: true)
    let appGroupDirectory =
      homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(
        HarnessMonitorMCPPreferencesDefaults.appGroupIdentifier,
        isDirectory: true
      )
    let socketPath =
      appGroupDirectory
      .appendingPathComponent(
        HarnessMonitorMCPPreferencesDefaults.socketFilename,
        isDirectory: false
      )
    let legacySocketPath =
      appGroupDirectory
      .appendingPathComponent("harness-monitor-mcp.sock", isDirectory: false)

    #expect(HarnessMonitorMCPPreferencesDefaults.socketFilename == "mcp.sock")
    #expect(socketPath.path.count < 104)
    #expect(legacySocketPath.path.count >= 104)
  }
}
