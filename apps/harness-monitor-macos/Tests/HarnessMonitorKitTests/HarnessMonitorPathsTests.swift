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
    expectedRoot = "/Users/example/Library/Application Support/harness/daemon"

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == expectedRoot
    )
  }

  @Test("External daemon mode still prefers the app group when one is available")
  func externalDaemonModePrefersAppGroup() {
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [
        DaemonOwnership.environmentKey: "1",
        HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier,
      ],
      homeDirectory: homeDirectory
    )

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .path
    )
  }

  @Test("Uses app group environment fallback")
  func usesAppGroupEnvironmentFallback() {
    let fallbackGroupIdentifier = "com.example.custom-group"
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: fallbackGroupIdentifier],
      homeDirectory: homeDirectory
    )

    #expect(
      HarnessMonitorPaths.authTokenURL(using: environment).path
        == expectedAppGroupRoot(
          identifier: fallbackGroupIdentifier,
          homeDirectory: homeDirectory
        )
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .appendingPathComponent("auth-token")
        .path
    )
  }

  @Test("Generated caches use a noindex root")
  func generatedCachesUseNoIndexRoot() {
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: homeDirectory
    )
    let expectedCacheRoot =
      expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("cache.noindex", isDirectory: true)
      .path

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

  @Test("Migrating generated caches removes indexed legacy thumbnail and notification directories")
  func migratingGeneratedCachesRemovesIndexedLegacyDirectories() throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-generated-cache-migration-\(UUID().uuidString)")
    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": dataHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
    let legacyThumbnailDirectory =
      harnessRoot.appendingPathComponent("cache/thumbnails", isDirectory: true)
    let legacyNotificationDirectory =
      harnessRoot.appendingPathComponent("cache/notifications", isDirectory: true)

    try FileManager.default.createDirectory(
      at: legacyThumbnailDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: legacyNotificationDirectory,
      withIntermediateDirectories: true
    )
    try Data("thumbnail".utf8).write(
      to: legacyThumbnailDirectory.appendingPathComponent("thumb.jpg"),
      options: .atomic
    )
    try Data("notification".utf8).write(
      to: legacyNotificationDirectory.appendingPathComponent("notice.png"),
      options: .atomic
    )

    try HarnessMonitorPaths.migrateLegacyGeneratedCaches(using: environment)

    #expect(
      FileManager.default.fileExists(
        atPath: HarnessMonitorPaths.generatedCacheRoot(using: environment).path
      )
    )
    #expect(FileManager.default.fileExists(atPath: legacyThumbnailDirectory.path) == false)
    #expect(FileManager.default.fileExists(atPath: legacyNotificationDirectory.path) == false)
  }

  @Test("Ensuring harness root non-indexable writes a metadata_never_index marker")
  func ensureHarnessRootNonIndexableWritesMarker() throws {
    let dataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-noindex-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dataHome) }
    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": dataHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: environment)

    let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
    let marker = harnessRoot.appendingPathComponent(".metadata_never_index")
    #expect(FileManager.default.fileExists(atPath: marker.path))

    // Second call must be idempotent.
    try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: environment)
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Ensuring harness root non-indexable avoids the app group parent")
  func ensureHarnessRootNonIndexableDoesNotMarkAppGroupRoot() throws {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-app-group-noindex-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: homeDirectory
    )

    try HarnessMonitorPaths.ensureHarnessRootNonIndexable(using: environment)

    let appGroupRoot = expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
    let appGroupMarker = appGroupRoot.appendingPathComponent(".metadata_never_index")
    let harnessMarker =
      appGroupRoot
      .appendingPathComponent(
        "harness",
        isDirectory: true
      )
      .appendingPathComponent(".metadata_never_index")
    #expect(FileManager.default.fileExists(atPath: appGroupMarker.path) == false)
    #expect(FileManager.default.fileExists(atPath: harnessMarker.path))
  }

  @Test("Tests skip native app group lookup for shared observability config")
  func sharedObservabilityConfigSkipsNativeAppGroupLookupUnderXCTest() {
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: homeDirectory
    )

    let expectedRoot =
      homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)

    #expect(
      HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment).path
        == expectedRoot
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("observability", isDirectory: true)
        .appendingPathComponent("config.json")
        .path
    )
  }

  @Test("Default app group env uses home-relative fallback under XCTest")
  func defaultAppGroupEnvironmentUsesHomeRelativeFallbackUnderXCTest() {
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: homeDirectory
    )

    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
        .path
    )
  }

  @Test("Shared observability config uses home-relative app group fallback under XCTest")
  func sharedObservabilityConfigUsesHomeRelativeAppGroupFallbackUnderXCTest() {
    let homeDirectory = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier],
      homeDirectory: homeDirectory
    )

    #expect(
      HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment).path
        == expectedDefaultAppGroupRoot(homeDirectory: homeDirectory)
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("observability", isDirectory: true)
        .appendingPathComponent("config.json")
        .path
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

private func expectedDefaultAppGroupRoot(homeDirectory: URL) -> URL {
  expectedAppGroupRoot(
    identifier: HarnessMonitorAppGroup.identifier,
    homeDirectory: homeDirectory
  )
}

private func expectedAppGroupRoot(identifier: String, homeDirectory: URL) -> URL {
  homeDirectory
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Group Containers", isDirectory: true)
    .appendingPathComponent(identifier, isDirectory: true)
}
